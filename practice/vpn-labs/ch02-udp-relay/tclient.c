/* tclient.c —— 隧道客户端：本地 TCP → UDP 帧封装（系列 ch02 §2.1）
 *
 * 在本地开一个 TCP 监听（如 :13000），应用连它；每条本地连接对应
 * 一个隧道会话：OPEN（携带真实目标）→ OPENACK → DATA 双向搬运 → CLOSE。
 * 帧格式与 relay.c 对齐：[type(1)][sid(4)][seq(4)][payload]。
 *
 * 用法：./tclient <本地TCP端口> <relay的IP:UDP端口> <真实目标host> <port>
 * 例：./tclient 13000 127.0.0.1:13001 127.0.0.1 8000
 * 然后 curl http://127.0.0.1:13000/ ——流量已穿隧道。
 */
#include "net_compat.h"

#define MAX_CONN 16
#define CHUNK 1200
#define OPEN_RETRY 3

enum { T_OPEN = 1, T_OPENACK = 2, T_DATA = 3, T_CLOSE = 4 };

struct conn {
    int used;
    SOCKET local_tcp;    /* 应用侧 */
    SOCKET udp;          /* 每连接独立 UDP 端点：帧里带 sid，天然多路复用 */
    struct sockaddr_in relay;
    uint32_t sid;
    uint32_t seq;
    int opened;
};

static void put32(uint8_t *p, uint32_t v)
{
    p[0] = v >> 24, p[1] = v >> 16, p[2] = v >> 8, p[3] = v;
}
static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

int main(int argc, char **argv)
{
    if (argc < 5) {
        fprintf(stderr, "用法: %s <本地端口> <relay IP:端口> <目标host> <目标port>\n",
                argv[0]);
        return 1;
    }
    net_init();
    setvbuf(stdout, NULL, _IONBF, 0);
    int lport = atoi(argv[1]);
    char rip[64] = "127.0.0.1";
    int rport = 13001;
    char *colon = strrchr(argv[2], ':');
    if (colon && colon[1] >= '0' && colon[1] <= '9') {
        snprintf(rip, sizeof rip, "%.*s", (int)(colon - argv[2]), argv[2]);
        rport = atoi(colon + 1);
    }
    char target[256];
    snprintf(target, sizeof target, "%s", argv[3]);
    int tport = atoi(argv[4]);

    SOCKET l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)lport);
    if (bind(l, (struct sockaddr *)&me, sizeof me) || listen(l, 8)) {
        fprintf(stderr, "bind/listen :%d 失败\n", lport);
        return 1;
    }
    printf("tclient :%d → relay %s:%d → 目标 %s:%d（Ctrl-C 退出）\n", lport, rip, rport,
           target, tport);

    struct conn cs[MAX_CONN] = { 0 };
    uint8_t buf[65536];

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(l, &rfds);
        int maxfd = (int)l;
        for (int i = 0; i < MAX_CONN; i++)
            if (cs[i].used) {
                FD_SET(cs[i].local_tcp, &rfds);
                FD_SET(cs[i].udp, &rfds);
                if ((int)cs[i].local_tcp > maxfd)
                    maxfd = (int)cs[i].local_tcp;
                if ((int)cs[i].udp > maxfd)
                    maxfd = (int)cs[i].udp;
            }
        struct timeval tv = { 1, 0 };
        select(maxfd + 1, &rfds, NULL, NULL, &tv);

        /* 新本地连接：建 UDP 会话，发 OPEN */
        if (FD_ISSET(l, &rfds)) {
            struct sockaddr_in ca;
            socklen_t cl = sizeof ca;
            SOCKET c = accept(l, (struct sockaddr *)&ca, &cl);
            struct conn *cn = NULL;
            for (int i = 0; i < MAX_CONN; i++)
                if (!cs[i].used)
                    cn = &cs[i];
            if (cn && c != INVALID_SOCKET) {
                memset(cn, 0, sizeof *cn);
                cn->used = 1;
                cn->local_tcp = c;
                cn->udp = socket(AF_INET, SOCK_DGRAM, 0);
                set_rcvtimeo(cn->udp, 400);
                cn->relay.sin_family = AF_INET;
                cn->relay.sin_port = htons((unsigned short)rport);
                cn->relay.sin_addr.s_addr = inet_addr(rip);
                uint8_t open[9 + 256];
                int hl = 9 + snprintf((char *)open + 9, sizeof open - 9, "%s%c%d", target,
                                      0, tport);
                open[0] = T_OPEN;
                put32(open + 1, 0);
                put32(open + 5, cn->seq++);
                for (int t = 0; t < OPEN_RETRY && !cn->opened; t++) {
                    sendto(cn->udp, (char *)open, hl, 0, (struct sockaddr *)&cn->relay,
                           sizeof cn->relay);
                    /* 等 OPENACK（失败再重试） */
                    for (;;) {
                        int n = recvfrom(cn->udp, (char *)buf, sizeof buf, 0, NULL, NULL);
                        if (n <= 0)
                            break; /* 超时 → 外层重试 */
                        if (buf[0] == T_OPENACK && n >= 6) {
                            cn->sid = get32(buf + 1);
                            if (buf[5]) {
                                cn->opened = 1;
                                printf("conn[%u] OPENACK sid=%u\n", cn->sid, cn->sid);
                            }
                            break;
                        }
                    }
                }
                if (!cn->opened) {
                    printf("OPEN 失败（relay 不可达或目标连不上），关闭本地连接\n");
                    CLOSE_SOCK(c);
                    CLOSE_SOCK(cn->udp);
                    cn->used = 0;
                }
            } else if (c != INVALID_SOCKET) {
                CLOSE_SOCK(c);
            }
        }

        for (int i = 0; i < MAX_CONN; i++) {
            struct conn *cn = &cs[i];
            if (!cn->used)
                continue;
            /* 应用侧可读 → DATA 帧 */
            if (FD_ISSET(cn->local_tcp, &rfds)) {
                char chunk[CHUNK];
                int n = recv(cn->local_tcp, chunk, sizeof chunk, 0);
                if (n <= 0) { /* 应用断开 → CLOSE，回收会话 */
                    uint8_t cl[9];
                    cl[0] = T_CLOSE;
                    put32(cl + 1, cn->sid);
                    put32(cl + 5, cn->seq++);
                    sendto(cn->udp, (char *)cl, 9, 0, (struct sockaddr *)&cn->relay,
                           sizeof cn->relay);
                    printf("conn[%u] CLOSE\n", cn->sid);
                    CLOSE_SOCK(cn->local_tcp);
                    CLOSE_SOCK(cn->udp);
                    cn->used = 0;
                    continue;
                }
                uint8_t pkt[9 + CHUNK];
                pkt[0] = T_DATA;
                put32(pkt + 1, cn->sid);
                put32(pkt + 5, cn->seq++);
                memcpy(pkt + 9, chunk, (size_t)n);
                sendto(cn->udp, (char *)pkt, 9 + n, 0, (struct sockaddr *)&cn->relay,
                       sizeof cn->relay);
            }
            /* 隧道侧可读 → 解帧写回应用 */
            if (cn->used && FD_ISSET(cn->udp, &rfds)) {
                int n = recvfrom(cn->udp, (char *)buf, sizeof buf, 0, NULL, NULL);
                if (n >= 9 && buf[0] == T_DATA && get32(buf + 1) == cn->sid)
                    send(cn->local_tcp, (const char *)buf + 9, n - 9, 0);
                else if (n >= 9 && buf[0] == T_CLOSE)
                    printf("conn[%u] 收到对端 CLOSE\n", cn->sid);
            }
        }
    }
}
