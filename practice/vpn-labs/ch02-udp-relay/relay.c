/* relay.c —— 明文 UDP 中继：隧道的服务端（系列 ch02 §2.2）
 *
 * 职责：监听一个 UDP 端口，按帧类型管理会话：
 *   OPEN(host\0port\0)  → 对目标发起 TCP，回 OPENACK，会话入表
 *   DATA(bytes)         → 写入会话的 TCP
 *   CLOSE               → 关闭 TCP，会话出表
 * TCP 侧可读 → 包成 DATA 帧发回客户端地址。
 * 会话回收：CLOSE 即删 + 30 秒无流量超时删（用户态 NAT 映射表）。
 * 主循环 select() 同时伺候 UDP 与全部 TCP socket。
 *
 * 用法：./relay [UDP端口=13001]
 */
#include "net_compat.h"
#include <time.h>

#define MAX_SESS 32
#define SESS_TIMEOUT 30 /* 秒 */
#define CHUNK 1200      /* DATA 分块上限：MTU 纪律（ch02 §2.4） */

enum { T_OPEN = 1, T_OPENACK = 2, T_DATA = 3, T_CLOSE = 4 };

struct sess {
    int used, sid;
    SOCKET tcp;
    struct sockaddr_in cli;
    long last_active;
    long bytes_in, bytes_out;
};

static long now_sec(void)
{
    return (long)(time(NULL));
}

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
    int port = argc > 1 ? atoi(argv[1]) : 13001;
    net_init();
    setvbuf(stdout, NULL, _IONBF, 0);
    SOCKET udp = socket(AF_INET, SOCK_DGRAM, 0);
    set_rcvtimeo(udp, 1000);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    if (bind(udp, (struct sockaddr *)&me, sizeof me)) {
        fprintf(stderr, "bind :%d 失败\n", port);
        return 1;
    }
    printf("relay :%d 就绪（明文 UDP 中继，会话超时 %ds）\n", port, SESS_TIMEOUT);

    struct sess ss[MAX_SESS] = { 0 };
    int next_sid = 1;
    uint8_t buf[65536];

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(udp, &rfds);
        int maxfd = (int)udp;
        for (int i = 0; i < MAX_SESS; i++)
            if (ss[i].used) {
                FD_SET(ss[i].tcp, &rfds);
                if ((int)ss[i].tcp > maxfd)
                    maxfd = (int)ss[i].tcp;
            }
        struct timeval tv = { 1, 0 };
        select(maxfd + 1, &rfds, NULL, NULL, &tv);

        /* ③ 每秒扫描：超时会话回收（CLOSE 没来也不泄漏） */
        for (int i = 0; i < MAX_SESS; i++)
            if (ss[i].used && now_sec() - ss[i].last_active > SESS_TIMEOUT) {
                printf("session=%d 超时回收（in=%ldB out=%ldB）\n", ss[i].sid,
                       ss[i].bytes_in, ss[i].bytes_out);
                CLOSE_SOCK(ss[i].tcp);
                ss[i].used = 0;
            }

        /* ① UDP 来帧 */
        if (FD_ISSET(udp, &rfds)) {
            struct sockaddr_in from;
            socklen_t fl = sizeof from;
            int n = recvfrom(udp, (char *)buf, sizeof buf, 0, (struct sockaddr *)&from, &fl);
            if (n >= 9) {
                int type = buf[0];
                uint32_t sid = get32(buf + 1), seq = get32(buf + 5);
                (void)seq; /* 明文阶段仅对账用 */
                const uint8_t *payload = buf + 9;
                int plen = n - 9;
                struct sess *s = NULL;
                for (int i = 0; i < MAX_SESS; i++)
                    if (ss[i].used && (uint32_t)ss[i].sid == sid)
                        s = &ss[i];

                if (type == T_OPEN && plen > 2) {
                    char host[128], ports[8];
                    const char *nul = memchr(payload, 0, (size_t)plen);
                    if (!nul)
                        continue;
                    snprintf(host, sizeof host, "%s", (const char *)payload);
                    snprintf(ports, sizeof ports, "%s", nul + 1);
                    SOCKET tcp = socket(AF_INET, SOCK_STREAM, 0);
                    struct sockaddr_in ta = { 0 };
                    ta.sin_family = AF_INET;
                    ta.sin_port = htons((unsigned short)atoi(ports));
                    ta.sin_addr.s_addr = inet_addr(host);
                    uint8_t ack[10];
                    ack[0] = T_OPENACK;
                    if (connect(tcp, (struct sockaddr *)&ta, sizeof ta) == 0) {
                        for (int i = 0; i < MAX_SESS; i++)
                            if (!ss[i].used) {
                                s = &ss[i];
                                break;
                            }
                        if (s) {
                            s->used = 1;
                            s->sid = next_sid++;
                            s->tcp = tcp;
                            s->cli = from;
                            s->last_active = now_sec();
                            s->bytes_in = s->bytes_out = 0;
                            set_rcvtimeo(tcp, 0); /* select 管超时，socket 不阻塞 */
                            put32(ack + 1, (uint32_t)s->sid);
                            ack[5] = 1;
                            printf("session=%d OPEN %s:%s → ok\n", s->sid, host, ports);
                        } else {
                            CLOSE_SOCK(tcp);
                            ack[5] = 0;
                        }
                    } else {
                        ack[5] = 0;
                        printf("session? OPEN %s:%s → 连接失败\n", host, ports);
                    }
                    if (!s)
                        put32(ack + 1, 0);
                    sendto(udp, (char *)ack, 6, 0, (struct sockaddr *)&from, fl);
                } else if (s && type == T_DATA) {
                    if (send(s->tcp, (const char *)payload, plen, 0) >= 0)
                        s->bytes_in += plen;
                    s->last_active = now_sec();
                } else if (s && type == T_CLOSE) {
                    printf("session=%d CLOSE（in=%ldB out=%ldB）\n", s->sid, s->bytes_in,
                           s->bytes_out);
                    CLOSE_SOCK(s->tcp);
                    s->used = 0;
                }
            }
        }

        /* ② 某条 TCP 可读 → 包成 DATA 帧回客户端 */
        for (int i = 0; i < MAX_SESS; i++) {
            if (!ss[i].used || !FD_ISSET(ss[i].tcp, &rfds))
                continue;
            char chunk[CHUNK];
            int n = recv(ss[i].tcp, chunk, sizeof chunk, 0);
            if (n <= 0) { /* 目标关闭：通知客户端 CLOSE */
                uint8_t cl[9];
                cl[0] = T_CLOSE;
                put32(cl + 1, (uint32_t)ss[i].sid);
                put32(cl + 5, 0);
                sendto(udp, (char *)cl, 9, 0, (struct sockaddr *)&ss[i].cli,
                       sizeof ss[i].cli);
                printf("session=%d 目标断开 → CLOSE 通知客户端（in=%ldB out=%ldB）\n",
                       ss[i].sid, ss[i].bytes_in, ss[i].bytes_out);
                CLOSE_SOCK(ss[i].tcp);
                ss[i].used = 0;
                continue;
            }
            uint8_t pkt[9 + CHUNK];
            pkt[0] = T_DATA;
            put32(pkt + 1, (uint32_t)ss[i].sid);
            put32(pkt + 5, 0);
            memcpy(pkt + 9, chunk, (size_t)n);
            sendto(udp, (char *)pkt, 9 + n, 0, (struct sockaddr *)&ss[i].cli,
                   sizeof ss[i].cli);
            ss[i].bytes_out += n;
            ss[i].last_active = now_sec();
        }
    }
}
