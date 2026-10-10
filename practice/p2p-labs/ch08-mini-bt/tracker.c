/* tracker.c —— HTTP 点名服务器（系列 ch08 §8.2，BEP 3 子集）
 *
 * 只做控制面：登记 peer、回 peer 列表，一个字节文件内容也不搬。
 * 与真实实现对齐：GET /announce、info_hash/peer_id/port/left 参数、
 * bencode 响应（interval/complete/incomplete/peers）。peers 用"字典列表"
 * 形式（非 compact），教学可读性优先；真实客户端两种都要支持。
 *
 * 用法：./tracker [端口=12080]
 */
#include "net_compat.h"
#include "bencode.h"
#include <time.h>

#define MAX_SWARM 64
#define MAX_PEERS 64

struct peer_rec {
    int used;
    char peer_id[21];
    char ip[24];
    int port;
    long left;
};
static struct {
    int used;
    char hash[21];
    struct peer_rec peers[MAX_PEERS];
} swarms[MAX_SWARM];

static void urldecode(char *dst, const char *src, int cap)
{
    int o = 0;
    for (int i = 0; src[i] && o < cap - 1; i++) {
        if (src[i] == '%' && src[i + 1] && src[i + 2]) {
            int hi = src[i + 1], lo = src[i + 2];
            int h = hi > '9' ? (hi | 32) - 'a' + 10 : hi - '0';
            int l = lo > '9' ? (lo | 32) - 'a' + 10 : lo - '0';
            dst[o++] = (char)(h * 16 + l);
            i += 2;
        } else if (src[i] != '+')
            dst[o++] = src[i];
    }
    dst[o] = 0;
}

/* 从查询串取参数（URL 解码后），找不到返回 0 */
static int qget(const char *q, const char *key, char *out, int cap)
{
    size_t klen = strlen(key);
    while (q && *q) {
        const char *amp = strchr(q, '&');
        size_t seg = amp ? (size_t)(amp - q) : strlen(q);
        if (seg > klen && !strncmp(q, key, klen) && q[klen] == '=') {
            char enc[256] = { 0 };
            size_t elen = seg - klen - 1;
            if (elen > sizeof enc - 1)
                elen = sizeof enc - 1;
            memcpy(enc, q + klen + 1, elen);
            urldecode(out, enc, cap);
            return 1;
        }
        q = amp ? amp + 1 : NULL;
    }
    return 0;
}

int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 12080;
    net_init();
    setvbuf(stdout, NULL, _IONBF, 0);
    SOCKET l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    if (bind(l, (struct sockaddr *)&me, sizeof me) || listen(l, 8)) {
        fprintf(stderr, "bind/listen :%d 失败\n", port);
        return 1;
    }
    printf("tracker :%d 就绪（HTTP announce，只做点名不搬数据）\n", port);

    for (;;) {
        struct sockaddr_in ca;
        socklen_t cl = sizeof ca;
        SOCKET c = accept(l, (struct sockaddr *)&ca, &cl);
        if (c == INVALID_SOCKET)
            continue;
        set_rcvtimeo(c, 2000);
        char req[4096] = { 0 };
        int n = recv(c, req, sizeof req - 1, 0);
        if (n <= 0) {
            CLOSE_SOCK(c);
            continue;
        }
        char method[8], path[2048];
        if (sscanf(req, "%7s %2047s", method, path) != 2 ||
            strcmp(method, "GET") || strncmp(path, "/announce", 9)) {
            CLOSE_SOCK(c);
            continue;
        }
        const char *q = strchr(path, '?');
        q = q ? q + 1 : "";

        char hash[24] = "", pid[64] = "", ips[24] = "", ports[8] = "", lefts[24] = "";
        qget(q, "info_hash", hash, 21);
        qget(q, "peer_id", pid, 40);
        qget(q, "ip", ips, sizeof ips);
        qget(q, "port", ports, sizeof ports);
        qget(q, "left", lefts, sizeof lefts);
        if (!hash[0] || !ports[0])
            pid[0] = pid[0]; /* 缺关键参数就当旁观，回空表 */

        int si = -1; /* 找/建 swarm */
        for (int i = 0; i < MAX_SWARM && si < 0; i++)
            if (swarms[i].used && !strcmp(swarms[i].hash, hash))
                si = i;
        if (si < 0)
            for (int i = 0; i < MAX_SWARM; i++)
                if (!swarms[i].used) {
                    si = i;
                    swarms[i].used = 1;
                    memcpy(swarms[i].hash, hash, 21);
                    break;
                }
        if (si < 0 || !pid[0]) {
            CLOSE_SOCK(c);
            continue;
        }

        int pi = -1; /* 登记/刷新 peer */
        for (int i = 0; i < MAX_PEERS; i++)
            if (swarms[si].peers[i].used && !strcmp(swarms[si].peers[i].peer_id, pid)) {
                pi = i;
                break;
            }
        if (pi < 0)
            for (int i = 0; i < MAX_PEERS; i++)
                if (!swarms[si].peers[i].used) {
                    pi = i;
                    swarms[si].peers[pi].used = 1;
                    break;
                }
        if (pi >= 0) {
            snprintf(swarms[si].peers[pi].peer_id, 21, "%s", pid);
            snprintf(swarms[si].peers[pi].ip, sizeof swarms[si].peers[pi].ip, "%s",
                     ips[0] ? ips : inet_ntoa(ca.sin_addr));
            swarms[si].peers[pi].port = atoi(ports);
            swarms[si].peers[pi].left = atol(lefts);
            printf("announce %-24s %s left=%s\n", swarms[si].peers[pi].peer_id,
                   swarms[si].peers[pi].ip, lefts[0] ? lefts : "0");
        }

        int complete = 0, incomplete = 0; /* 回表：别人（不含自己）*/
        struct bval *peers = blist();
        for (int i = 0; i < MAX_PEERS; i++) {
            struct peer_rec *pr = &swarms[si].peers[i];
            if (!pr->used)
                continue;
            if (pr->left > 0)
                incomplete++;
            else
                complete++;
            if (pi >= 0 && i == pi)
                continue;
            struct bval *d = bdict();
            bput(d, "ip", bstr(pr->ip, (size_t)-1));
            bput(d, "peer id", bstr(pr->peer_id, (size_t)-1));
            bput(d, "port", bint(pr->port));
            bappend(peers, d);
        }
        struct bval *resp = bdict();
        bput(resp, "complete", bint(complete));
        bput(resp, "incomplete", bint(incomplete));
        bput(resp, "interval", bint(1800));
        bput(resp, "peers", peers);
        size_t rlen;
        char *renc = bencode(resp, &rlen);

        char hdr[128];
        int hl = snprintf(hdr, sizeof hdr,
                          "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n"
                          "Content-Length: %zu\r\n\r\n", rlen);
        send(c, hdr, hl, 0);
        send(c, renc, (int)rlen, 0);
        CLOSE_SOCK(c);
        free(renc), bfree(resp);
    }
}
