/* peer.c —— 对称 UDP 聊天：一份代码，收发同体（系列 ch02 §2.1）
 *
 * 没有 listen/accept 的身份仪式，"谁是服务端"退化为"谁先发第一条消息"。
 * 同伴表 peers[] 就是路由表的第 0 号版本：陌生对端的消息自动入表。
 * 并发说明：演示级不加锁（peers 只在接收线程追加，主线程只读遍历发送）；
 * 真实项目这里应该有一把 mutex——把它找出来加锁，是很好的课后练习。
 *
 * 用法（两个终端，或两台同网段机器互换地址）：
 *   ./peer <我的端口> <对端IP:端口> [<对端IP:端口> ...]
 *   ./peer 12000 192.168.1.20:12001
 * 输入消息回车发送；quit 退出；收到消息实时打印。
 */
#include "net_compat.h"

#define MAX_PEERS 16
#define HELLO_INTERVAL 10 /* 秒：应用层心跳，ch03 NAT 保活思想的影子 */

struct ctx {
    SOCKET sock;
    struct sockaddr_in peers[MAX_PEERS];
    int npeers;
};

static void add_peer(struct ctx *c, struct sockaddr_in a)
{
    for (int i = 0; i < c->npeers; i++)
        if (c->peers[i].sin_port == a.sin_port &&
            c->peers[i].sin_addr.s_addr == a.sin_addr.s_addr)
            return;
    if (c->npeers < MAX_PEERS)
        c->peers[c->npeers++] = a; /* 陌生对端自动入表：对等网络的"发现" */
}

static void send_all(struct ctx *c, const char *msg)
{
    for (int i = 0; i < c->npeers; i++)
        sendto(c->sock, msg, (int)strlen(msg), 0,
               (struct sockaddr *)&c->peers[i], sizeof c->peers[i]);
}

#ifdef _WIN32
static void sleep_(int s) { Sleep(s * 1000); }
#else
#include <unistd.h>
static void sleep_(int s) { sleep(s); }
#endif

static void receiver(void *arg)
{
    struct ctx *c = arg;
    char buf[2048];
    for (;;) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(c->sock, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0)
            continue; /* 超时/被打断：继续等 */
        buf[n] = 0;
        add_peer(c, from);
        printf("\r<%s:%u> %s\n> ", inet_ntoa(from.sin_addr), ntohs(from.sin_port), buf);
        fflush(stdout);
    }
}

static void heartbeat(void *arg)
{
    struct ctx *c = arg;
    for (;;) {
        sleep_(HELLO_INTERVAL);
        send_all(c, "[heartbeat]");
    }
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <我的端口> <对端IP:端口>...\n", argv[0]);
        return 1;
    }
    net_init();
    struct ctx c = { 0 };
    c.sock = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)atoi(argv[1]));
    bind(c.sock, (struct sockaddr *)&me, sizeof me);

    for (int i = 2; i < argc; i++) {
        char *ip = argv[i], *colon = strrchr(ip, ':');
        if (!colon)
            continue;
        *colon = 0;
        struct sockaddr_in a = { 0 };
        a.sin_family = AF_INET;
        a.sin_port = htons((unsigned short)atoi(colon + 1));
        a.sin_addr.s_addr = inet_addr(ip);
        c.peers[c.npeers++] = a;
    }

    thread_start(receiver, &c);
    thread_start(heartbeat, &c);
    printf("peer 已启动 0.0.0.0:%d，同伴 %d 个；输入消息回车发送，quit 退出\n",
           atoi(argv[1]), c.npeers);

    char line[1024];
    while (printf("> "), fflush(stdout), fgets(line, sizeof line, stdin)) {
        line[strcspn(line, "\r\n")] = 0;
        if (strcmp(line, "quit") == 0)
            break;
        if (line[0])
            send_all(&c, line);
    }
    net_cleanup();
    return 0;
}
