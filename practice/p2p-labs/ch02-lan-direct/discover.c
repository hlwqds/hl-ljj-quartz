/* discover.c —— UDP 广播发现局域网同伴（系列 ch02 §2.2）
 *
 * 协议两条文本报文（对齐 Gnutella 的"简单到可以在名片背面写完"精神）：
 *   HELLO <name>\n   广播喊话："有人吗？我是 xxx"
 *   HERE  <name>\n   单播回应："我在，我是 yyy"
 *
 * 局域网用法（两台机器各跑一份，端口相同）：
 *   ./discover --name alice --port 12010
 * 本机双进程演示（两个终端，端口互换；--target 指到对端模拟"广播可达"）：
 *   ./discover --name alice --port 12011 --target 127.0.0.1:12012
 *   ./discover --name bob   --port 12012 --target 127.0.0.1:12011
 */
#include "net_compat.h"

#ifdef _WIN32
static void sleep_ms(int ms) { Sleep(ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep(ms * 1000); }
#endif

#define MAX_PEERS 32

struct ctx {
    SOCKET sock;
    const char *myname;
    struct {
        struct sockaddr_in a;
        char name[32];
    } peers[MAX_PEERS];
    volatile int npeers;
};

static void note_peer(struct ctx *c, struct sockaddr_in a, const char *name)
{
    for (int i = 0; i < c->npeers; i++)
        if (c->peers[i].a.sin_port == a.sin_port &&
            c->peers[i].a.sin_addr.s_addr == a.sin_addr.s_addr)
            return;
    if (c->npeers < MAX_PEERS) {
        c->peers[c->npeers].a = a;
        snprintf(c->peers[c->npeers].name, sizeof c->peers[0].name, "%s", name);
        c->npeers++;
        printf("[发现] %s @ %s:%u\n", name, inet_ntoa(a.sin_addr), ntohs(a.sin_port));
    }
}

static void receiver(void *arg)
{
    struct ctx *c = arg;
    char buf[256];
    for (;;) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(c->sock, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0)
            continue;
        buf[n] = 0;
        char cmd[16], name[64];
        if (sscanf(buf, "%15s %63s", cmd, name) != 2)
            continue;
        if (strcmp(cmd, "HELLO") == 0) {
            char here[80];
            snprintf(here, sizeof here, "HERE %s\n", c->myname);
            sendto(c->sock, here, (int)strlen(here), 0, (struct sockaddr *)&from, fl);
            note_peer(c, from, name);
        } else if (strcmp(cmd, "HERE") == 0) {
            note_peer(c, from, name);
        }
    }
}

int main(int argc, char **argv)
{
    const char *name = NULL, *target = NULL;
    int port = 12010, interval_ms = 1000;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--name") && i + 1 < argc)
            name = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc)
            port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--target") && i + 1 < argc)
            target = argv[++i];
        else if (!strcmp(argv[i], "--interval") && i + 1 < argc)
            interval_ms = atoi(argv[++i]);
    }
    if (!name) {
        fprintf(stderr, "用法: %s --name <名字> [--port 12010] [--target 广播地址:端口]\n",
                argv[0]);
        return 1;
    }

    char bip[64] = "255.255.255.255";
    int bport = port;
    if (target) {
        char *colon = strrchr(target, ':');
        if (colon) {
            *colon = 0;
            snprintf(bip, sizeof bip, "%s", target);
            bport = atoi(colon + 1);
        }
    }

    net_init();
    struct ctx c = { 0 };
    c.myname = name;
    c.sock = socket(AF_INET, SOCK_DGRAM, 0);
    int on = 1;
    setsockopt(c.sock, SOL_SOCKET, SO_BROADCAST, (const char *)&on, sizeof on);
    setsockopt(c.sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&on, sizeof on);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    bind(c.sock, (struct sockaddr *)&me, sizeof me);

    struct sockaddr_in bc = { 0 };
    bc.sin_family = AF_INET;
    bc.sin_port = htons((unsigned short)bport);
    bc.sin_addr.s_addr = inet_addr(bip);

    thread_start(receiver, &c);
    char hello[80];
    snprintf(hello, sizeof hello, "HELLO %s\n", name);
    printf("广播 %s:%d 每 %dms 一次，Ctrl-C 结束\n", bip, bport, interval_ms);

    for (int tick = 0;; tick++) {
        sendto(c.sock, hello, (int)strlen(hello), 0, (struct sockaddr *)&bc, sizeof bc);
        sleep_ms(interval_ms);
        if (tick > 0 && tick % 10 == 0) { /* 周期快照：同伴表 = 路由表第 0 版 */
            printf("—— 同伴表（%d）——\n", c.npeers);
            for (int i = 0; i < c.npeers; i++)
                printf("  %-10s %s:%u\n", c.peers[i].name,
                       inet_ntoa(c.peers[i].a.sin_addr),
                       ntohs(c.peers[i].a.sin_port));
        }
    }
}
