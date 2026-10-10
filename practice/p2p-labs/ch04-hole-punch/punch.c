/* punch.c —— 打洞端（系列 ch04 §4.1 的 A/B 角色）
 *
 * 时序复刻章内的三步：①向引路服务器 REG（重试至 ACK）→ ②收到 PEER 情报
 * → ③双方同时向对方观测地址互射 PUNCH（首包被丢是施工不是失败），
 * 收到对方的 PUNCH 即回 PONG，收到 PONG 判定洞通。此后进入聊天 + 周期
 * keepalive 维持 NAT 映射（ch03：UDP 映射寿命短）。
 *
 * 全程单一 socket——探测、登记、开打必须同一个本地端点（ch03 run.log 里
 * 那次翻车的教训，这里焊死在结构里）。
 *
 * 用法：./punch --server <ip:port> --room demo --name A
 * 真实互联网实验：两台不同 NAT 后的机器各跑一份，--server 指向公网引路
 * 服务器（rendezvous 部署在有公网 IP 的机器上即可）。
 */
#include "net_compat.h"
#include <time.h>

#ifdef _WIN32
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif

static long now_ms(void) /* 相对启动的毫秒钟：时序教学用 */
{
    return (long)(clock() * 1000 / CLOCKS_PER_SEC);
}

struct ctx {
    SOCKET sock;
    char myname[32];
    struct sockaddr_in server;
    volatile int have_peer;
    volatile int connected;
    struct sockaddr_in peer;
    char peername[32];
    long t0;
};

static void send_line(struct ctx *c, const char *line, const struct sockaddr_in *to)
{
    sendto(c->sock, line, (int)strlen(line), 0, (struct sockaddr *)to, sizeof *to);
}

static void receiver(void *arg)
{
    struct ctx *c = arg;
    char buf[2048];
    for (;;) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(c->sock, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0)
            continue;
        buf[n] = 0;
        long t = now_ms() - c->t0;

        if (!strncmp(buf, "PEER ", 5)) { /* ② 情报到达：记住对端，标记可开打 */
            char ip[32];
            unsigned port;
            sscanf(buf + 5, "%31s %31s %u", c->peername, ip, &port);
            c->peer.sin_family = AF_INET;
            c->peer.sin_port = htons((unsigned short)port);
            c->peer.sin_addr.s_addr = inet_addr(ip);
            c->have_peer = 1;
            printf("[%5ldms] 情报：%s @ %s:%u —— 开始互射\n", t, c->peername, ip, port);
        } else if (!strncmp(buf, "PUNCH ", 6)) { /* ③ 对方的施工包到了：回 PONG */
            char reply[48];
            snprintf(reply, sizeof reply, "PONG %s", c->myname);
            send_line(c, reply, &from);
            if (!c->connected)
                printf("[%5ldms] 收到 %s 的打洞包，回 PONG —— 洞通！\n", t, buf + 6);
            c->connected = 1;
        } else if (!strncmp(buf, "PONG ", 5)) {
            if (!c->connected)
                printf("[%5ldms] 收到 PONG —— 洞通确认\n", t);
            c->connected = 1;
        } else if (buf[0] == 'A' && buf[1] == 'C' && buf[2] == 'K') {
            /* 登记确认：静默 */
        } else {
            printf("[%5ldms] <%s:%u> %s\n", t, inet_ntoa(from.sin_addr),
                   ntohs(from.sin_port), buf);
        }
    }
}

static void keepalive(void *arg) /* ch03 的映射保活：UDP 映射会过期 */
{
    struct ctx *c = arg;
    for (;;) {
        sleep_ms(3000);
        if (c->have_peer)
            send_line(c, "[keepalive]", &c->peer);
    }
}

int main(int argc, char **argv)
{
    struct ctx c = { 0 };
    c.t0 = now_ms();
    char sip[32] = "127.0.0.1";
    int sport = 12050;
    char room[32] = "demo";
    snprintf(c.myname, sizeof c.myname, "peer");
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--server") && i + 1 < argc) {
            char *v = argv[++i], *colon = strrchr(v, ':');
            if (colon && colon[1] >= '0' && colon[1] <= '9') {
                *colon = 0;
                snprintf(sip, sizeof sip, "%s", v);
                sport = atoi(colon + 1);
            } else
                snprintf(sip, sizeof sip, "%s", v);
        } else if (!strcmp(argv[i], "--name") && i + 1 < argc) {
            snprintf(c.myname, sizeof c.myname, "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--room") && i + 1 < argc) {
            snprintf(room, sizeof room, "%s", argv[++i]);
        }
    }

    net_init();
    c.server.sin_family = AF_INET;
    c.server.sin_port = htons((unsigned short)sport);
    c.server.sin_addr.s_addr = inet_addr(sip);

    c.sock = socket(AF_INET, SOCK_DGRAM, 0); /* 全程唯一 socket（纪律） */
    set_rcvtimeo(c.sock, 300);
    thread_start(receiver, &c);
    thread_start(keepalive, &c);

    char reg[80];
    snprintf(reg, sizeof reg, "REG %s %s", room, c.myname);
    printf("[%5ldms] %s 向 %s:%d 登记（room=%s）\n", 0L, c.myname, sip, sport, room);
    while (!c.have_peer) { /* ① 重试登记直到配对情报到来 */
        send_line(&c, reg, &c.server);
        sleep_ms(300);
    }

    char punch[48]; /* ③ 互射：10 发、间隔 50ms；对方 NAT 未就绪的前几发被丢很正常 */
    snprintf(punch, sizeof punch, "PUNCH %s", c.myname);
    for (int i = 0; i < 10; i++) {
        send_line(&c, punch, &c.peer);
        sleep_ms(50);
    }
    while (!c.connected)
        sleep_ms(50); /* receiver 线程在收 PONG/PUNCH */

    printf("[%5ldms] === P2P 直连建立（引路服务器已退场），输入消息回车发送 ===\n",
           now_ms() - c.t0);
    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (line[0])
            send_line(&c, line, &c.peer);
    }
    net_cleanup();
    return 0;
}
