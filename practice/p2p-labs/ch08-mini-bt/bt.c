/* bt.c —— 迷你 BitTorrent 客户端：做种 / 取种（系列 ch08 §8.2–§8.4）
 *
 * 线缆协议子集（对齐 BEP 3）：握手（19+协议名+保留8B+infohash+peer_id）、
 * 消息帧（4B 长度+1B ID）、choke/unchoke/interested/bitfield/request/piece。
 * 两级分片：piece（校验单位，SHA-1）× block（传输单位，16 KiB，8 块流水线）。
 * 简化：单 peer 顺序取种、无 endgame/choke 博弈（那些在 ch08 §8.5 讲清楚了，
 * 单 peer 场景也无从博弈）；分片策略是"顺序流水"，真实客户端用稀缺优先。
 *
 * 用法：
 *   ./bt seed <file.torrent> <数据文件> [监听端口=12101]
 *   ./bt get  <file.torrent> <输出文件>
 */
#include "net_compat.h"
#include "bencode.h"
#include "sha1.h"
#include <time.h>
#ifdef _WIN32
#include <process.h>
#define GETPID() _getpid()
#else
#include <unistd.h>
#define GETPID() getpid()
#endif

#define BLOCK 16384
#define PIPELINE 8
#define ID_CHOKE 0
#define ID_UNCHOKE 1
#define ID_INTERESTED 2
#define ID_NOT_INTERESTED 3
#define ID_HAVE 4
#define ID_BITFIELD 5
#define ID_REQUEST 6
#define ID_PIECE 7
#define ID_CANCEL 8

static char my_peer_id[21];

struct torrent {
    char announce_ip[64];
    int announce_port;
    uint8_t infohash[20];
    long piecelen, length, npieces;
    uint8_t *pieces; /* 20×npieces */
    char name[128];
};

struct peer_addr {
    char ip[32];
    int port;
};

static void die(const char *msg)
{
    fprintf(stderr, "bt: %s\n", msg);
    exit(1);
}

/* ---- 种子文件 ---- */

static void load_torrent(const char *path, struct torrent *t)
{
    FILE *f = fopen(path, "rb");
    if (!f)
        die("打不开种子文件");
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *buf = malloc(sz);
    fread(buf, 1, sz, f);
    fclose(f);

    struct bval *tv = bdecode(buf, (size_t)sz, NULL);
    if (!tv)
        die("种子文件 bencode 解析失败");
    struct bval *info = bget(tv, "info");
    struct bval *ann = bget(tv, "announce");
    struct bval *pl = bget(info, "piece length");
    struct bval *pcs = bget(info, "pieces");
    struct bval *len = bget(info, "length");
    struct bval *name = bget(info, "name");
    if (!info || !ann || !pl || !pcs || !len)
        die("种子缺字段");

    /* announce: http://ip:port/announce */
    const char *s = ann->s + 7;
    const char *slash = strchr(s, '/');
    char hp[80];
    snprintf(hp, sizeof hp, "%.*s", (int)(slash ? slash - s : (long)strlen(s)), s);
    char *colon = strrchr(hp, ':');
    *colon = 0;
    snprintf(t->announce_ip, sizeof t->announce_ip, "%s", hp);
    t->announce_port = atoi(colon + 1);

    t->piecelen = pl->i;
    t->length = len->i;
    t->npieces = (long)pcs->slen / 20;
    t->pieces = malloc(pcs->slen);
    memcpy(t->pieces, pcs->s, pcs->slen);
    snprintf(t->name, sizeof t->name, "%.*s", (int)(name->slen < 127 ? name->slen : 127),
             name->s);

    size_t ilen;
    char *ienc = bencode(info, &ilen); /* infohash = SHA-1(规范编码的 info) */
    uint8_t ih[20];
    sha1(ienc, ilen, ih);
    memcpy(t->infohash, ih, 20);
    bfree(tv), free(buf), free(ienc);
}

/* ---- HTTP announce（BEP 3 子集：GET + bencode 响应） ---- */

static int announce(const struct torrent *t, long left, const char *event,
                    struct peer_addr *out, int maxout)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { 0 };
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)t->announce_port);
    a.sin_addr.s_addr = inet_addr(t->announce_ip);
    if (connect(s, (struct sockaddr *)&a, sizeof a))
        die("连不上 tracker（先起 tracker？）");
    set_rcvtimeo(s, 3000);

    char req[1024], enc_hash[64] = "", enc_pid[128] = "";
    for (int i = 0; i < 20; i++) /* info_hash/peer_id 要 URL 编码（非可打印） */
        sprintf(enc_hash + strlen(enc_hash), "%%%02x", t->infohash[i]);
    for (char *p = my_peer_id; *p; p++)
        sprintf(enc_pid + strlen(enc_pid), *p < '!' ? "%%%02x" : "%c", *p & 0xff);
    char q[768];
    int qn = snprintf(q, sizeof q,
                      "info_hash=%s&peer_id=%s&port=12101&uploaded=0&downloaded=0&left=%ld",
                      enc_hash, enc_pid, left);
    if (event[0])
        qn += snprintf(q + qn, sizeof q - (size_t)qn, "&event=%s", event);
    snprintf(req, sizeof req, "GET /announce?%s HTTP/1.0\r\n\r\n", q);
    send(s, req, (int)strlen(req), 0);

    char resp[65536] = { 0 };
    int n = 0, r;
    while ((r = recv(s, resp + n, sizeof resp - 1 - n, 0)) > 0)
        n += r;
    CLOSE_SOCK(s);
    char *body = strstr(resp, "\r\n\r\n");
    if (!body)
        die("tracker 响应无 HTTP 体");
    body += 4;

    struct bval *bv = bdecode(body, (size_t)n - (body - resp), NULL);
    if (!bv)
        die("tracker 响应 bencode 解析失败");
    struct bval *peers = bget(bv, "peers");
    int cnt = 0;
    if (peers && peers->type == 'l')
        for (size_t i = 0; i < peers->nitems && cnt < maxout; i++) {
            struct bval *d = peers->items[i];
            struct bval *ip = bget(d, "ip"), *pt = bget(d, "port");
            if (ip && pt) {
                snprintf(out[cnt].ip, sizeof out[cnt].ip, "%.*s", (int)ip->slen, ip->s);
                out[cnt].port = (int)pt->i;
                cnt++;
            }
        }
    bfree(bv);
    return cnt;
}

/* ---- 线缆协议 ---- */

static void send_handshake(SOCKET s, const struct torrent *t)
{
    char hs[68];
    hs[0] = 19;
    memcpy(hs + 1, "BitTorrent protocol", 19);
    memset(hs + 20, 0, 8); /* 保留位：本迷你客户端不支持 DHT/扩展协议 */
    memcpy(hs + 28, t->infohash, 20);
    memcpy(hs + 48, my_peer_id, 20);
    send(s, hs, 68, 0);
}

static int recv_exact(SOCKET s, char *buf, int len)
{
    int got = 0;
    while (got < len) {
        int n = recv(s, buf + got, len - got, 0);
        if (n <= 0)
            return 0;
        got += n;
    }
    return 1;
}

static int recv_handshake(SOCKET s, const struct torrent *t)
{
    char hs[68];
    if (!recv_exact(s, hs, 68) || hs[0] != 19 || memcmp(hs + 1, "BitTorrent protocol", 19))
        return 0;
    if (memcmp(hs + 28, t->infohash, 20)) /* 连错 swarm：立即断 */
        return 0;
    return 1;
}

static int send_msg(SOCKET s, int id, const void *payload, int plen)
{
    char hdr[5];
    uint32_t len = (uint32_t)(plen + 1);
    hdr[0] = len >> 24, hdr[1] = len >> 16, hdr[2] = len >> 8, hdr[3] = (char)len;
    hdr[4] = (char)id;
    if (send(s, hdr, 5, 0) != 5)
        return 0;
    if (plen && send(s, payload, plen, 0) != plen)
        return 0;
    return 1;
}

/* 读一条消息（keepalive 返回 id=-1）；payload 缓冲由调用方给 */
static int recv_msg(SOCKET s, int *id, char *payload, int cap, int *plen)
{
    char hdr[4];
    if (!recv_exact(s, hdr, 4))
        return 0;
    uint32_t len = (uint8_t)hdr[0] << 24 | (uint8_t)hdr[1] << 16 | (uint8_t)hdr[2] << 8 |
                   (uint8_t)hdr[3];
    if (len == 0) {
        *id = -1;
        *plen = 0;
        return 1;
    }
    if (len == 0) {
        *id = -1;
        *plen = 0;
        return 1;
    }
    if (len > (uint32_t)cap)
        return 0;
    if (!recv_exact(s, payload, (int)len)) /* 消息体 = 1B ID + 载荷，整读 */
        return 0;
    *id = payload[0];
    *plen = (int)len - 1;
    return 1;
}

/* ---- 做种 ---- */

static int seed_mode(const char *tpath, const char *fpath, int port)
{
    struct torrent t;
    load_torrent(tpath, &t);
    FILE *f = fopen(fpath, "rb");
    if (!f)
        die("打不开数据文件");
    uint8_t *blob = malloc(t.length);
    fread(blob, 1, t.length, f);
    fclose(f);

    struct peer_addr pas[16];
    int np = announce(&t, 0, "started", pas, 16); /* 登记（left=0：我是做种者） */
    printf("[seed] %s 已向 tracker 登记（infohash 前 8 位 %02x%02x%02x%02x…）\n",
           my_peer_id, t.infohash[0], t.infohash[1], t.infohash[2], t.infohash[3]);
    (void)np;

    SOCKET l = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    if (bind(l, (struct sockaddr *)&me, sizeof me) || listen(l, 4))
        die("做种监听端口绑定失败");
    printf("[seed] 监听 :%d，等待 leecher 握手（Ctrl-C 退出）\n", port);

    for (;;) {
        struct sockaddr_in ca;
        socklen_t cl = sizeof ca;
        SOCKET c = accept(l, (struct sockaddr *)&ca, &cl);
        if (c == INVALID_SOCKET)
            continue;
        set_rcvtimeo(c, 10000);
        if (!recv_handshake(c, &t)) {
            CLOSE_SOCK(c);
            continue;
        }
        send_handshake(c, &t);
        printf("[seed] 握手完成 %s:%u —— 发 bitfield（%ld 片全有）\n",
               inet_ntoa(ca.sin_addr), ntohs(ca.sin_port), t.npieces);
        int bytelen = (int)((t.npieces + 7) / 8);
        char *bf = calloc(1, bytelen);
        for (long i = 0; i < t.npieces; i++)
            bf[i / 8] |= 0x80 >> (i % 8);
        send_msg(c, ID_BITFIELD, bf, bytelen);

        long served = 0;
        char payload[BLOCK + 16];
        for (;;) { /* 服务循环：interested→unchoke，request→piece */
            int id, plen;
            if (!recv_msg(c, &id, payload, sizeof payload, &plen))
                break;
            if (id == ID_INTERESTED) {
                printf("[seed] 对端 interested → unchoke（单对端场景：直接放行）\n");
                send_msg(c, ID_UNCHOKE, NULL, 0);
            } else if (id == ID_REQUEST && plen >= 12) {
                long idx = (uint8_t)payload[1] << 24 | (uint8_t)payload[2] << 16 |
                           (uint8_t)payload[3] << 8 | (uint8_t)payload[4];
                long begin = (uint8_t)payload[5] << 24 | (uint8_t)payload[6] << 16 |
                             (uint8_t)payload[7] << 8 | (uint8_t)payload[8];
                long blen = (uint8_t)payload[9] << 24 | (uint8_t)payload[10] << 16 |
                            (uint8_t)payload[11] << 8 | (uint8_t)payload[12];
                if (idx >= 0 && idx < t.npieces && blen <= BLOCK) {
                    char out[BLOCK + 8]; /* 载荷 = idx4 + begin4 + data（ID 由 send_msg 带） */
                    out[0] = idx >> 24, out[1] = idx >> 16, out[2] = idx >> 8,
                    out[3] = idx;
                    out[4] = begin >> 24, out[5] = begin >> 16, out[6] = begin >> 8,
                    out[7] = begin;
                    memcpy(out + 8, blob + idx * t.piecelen + begin, blen);
                    send_msg(c, ID_PIECE, out, 8 + (int)blen);
                    if (++served % 16 == 0)
                        printf("[seed] 已服务 %ld 块…\n", served);
                }
            } else if (id >= 0) {
                printf("[seed] 消息 id=%d（忽略）\n", id);
            }
        }
        printf("[seed] 对端断开（共服务 %ld 块），继续等待下一个\n", served);
        CLOSE_SOCK(c);
    }
    return 0;
}

/* ---- 取种 ---- */

static int get_mode(const char *tpath, const char *outpath)
{
    struct torrent t;
    load_torrent(tpath, &t);
    struct peer_addr pas[16];
    int np = announce(&t, t.length, "started", pas, 16);
    printf("[get ] tracker 回了 %d 个 peer\n", np);
    if (!np)
        die("swarm 里没有别人（先起 seeder？）");

    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a = { 0 };
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)pas[0].port);
    a.sin_addr.s_addr = inet_addr(pas[0].ip);
    if (connect(s, (struct sockaddr *)&a, sizeof a))
        die("连不上 peer");
    set_rcvtimeo(s, 8000);
    send_handshake(s, &t);
    if (!recv_handshake(s, &t))
        die("握手失败（infohash 不匹配？）");
    printf("[get ] 握手完成 %s:%d —— 发 interested\n", pas[0].ip, pas[0].port);
    send_msg(s, ID_INTERESTED, NULL, 0);

    /* 等 unchoke（期间吞掉 bitfield/keepalive/have） */
    int id, plen, choked = 1;
    char payload[BLOCK + 16];
    while (choked) {
        if (!recv_msg(s, &id, payload, sizeof payload, &plen))
            die("等 unchoke 时连接断开");
        if (id == ID_UNCHOKE) {
            choked = 0;
            printf("[get ] 收到 unchoke —— 开始请求（%ld 片 × %d B 块，流水线 %d）\n",
                   t.npieces, BLOCK, PIPELINE);
        } else if (id == ID_BITFIELD)
            printf("[get ] 收到 bitfield（%d B 位图）\n", plen);
    }

    uint8_t *blob = calloc(1, t.length);
    char *have = calloc(1, t.npieces + 1);
    long done_pieces = 0, downloaded = 0;

    for (long p = 0; p < t.npieces; p++) {
        long plen_piece = t.length - p * t.piecelen < t.piecelen
                              ? t.length - p * t.piecelen
                              : t.piecelen;
        long nblocks = (plen_piece + BLOCK - 1) / BLOCK;
        char *blkhave = calloc(1, (size_t)nblocks + 1);
        long gotblocks = 0;
        while (gotblocks < nblocks) {
            /* 补流水线：在途不足 PIPELINE 就发 request */
            long inflight = 0;
            for (long b = 0; b < nblocks; b++) {
                if (blkhave[b] == 2)
                    inflight++;
            }
            for (long b = 0; b < nblocks && inflight < PIPELINE; b++)
                if (!blkhave[b]) {
                    long begin = b * BLOCK;
                    long blen = plen_piece - begin < BLOCK ? plen_piece - begin : BLOCK;
                    char req[12];
                    req[0] = p >> 24, req[1] = p >> 16, req[2] = p >> 8, req[3] = p;
                    req[4] = begin >> 24, req[5] = begin >> 16, req[6] = begin >> 8,
                    req[7] = begin;
                    req[8] = blen >> 24, req[9] = blen >> 16, req[10] = blen >> 8,
                    req[11] = blen;
                    send_msg(s, ID_REQUEST, req, 12);
                    blkhave[b] = 2;
                    inflight++;
                }
            /* 收一块 */
            if (!recv_msg(s, &id, payload, sizeof payload, &plen))
                die("传输中连接断开");
            if (id != ID_PIECE)
                continue;
            long idx = (uint8_t)payload[1] << 24 | (uint8_t)payload[2] << 16 |
                       (uint8_t)payload[3] << 8 | (uint8_t)payload[4];
            long begin = (uint8_t)payload[5] << 24 | (uint8_t)payload[6] << 16 |
                         (uint8_t)payload[7] << 8 | (uint8_t)payload[8];
            long blen = plen - 8; /* 载荷（不含 ID）= idx4 + begin4 + data */
            if (idx != p || begin < 0 || begin + blen > plen_piece)
                continue; /* 不是当前片的块：丢弃（真实客户端会缓存） */
            memcpy(blob + p * t.piecelen + begin, payload + 9, blen);
            blkhave[begin / BLOCK] = 1;
            gotblocks++;
            downloaded += blen;
        }
        /* 整片到齐 → SHA-1 验收（ch08：永远不要信任网络另一端） */
        uint8_t dig[20];
        sha1(blob + p * t.piecelen, (size_t)plen_piece, dig);
        if (memcmp(dig, t.pieces + p * 20, 20)) {
            fprintf(stderr, "\n[get ] 第 %ld 片 SHA-1 不匹配！中止。\n", p);
            return 1;
        }
        have[p] = 1;
        done_pieces++;
        free(blkhave);
        printf("\r[get ] %ld/%ld 片验收通过（%ld B）   ", done_pieces, t.npieces,
               downloaded);
        fflush(stdout);
    }
    printf("\n");

    FILE *f = fopen(outpath, "wb");
    fwrite(blob, 1, t.length, f);
    fclose(f);
    printf("[get ] 全部 %ld 片通过 SHA-1，已写 %s（%ld B）\n", t.npieces, outpath,
           t.length);
    announce(&t, 0, "completed", pas, 16); /* completed 事件（单机演示留痕） */
    return 0;
}

int main(int argc, char **argv)
{
    net_init();
    setvbuf(stdout, NULL, _IONBF, 0); /* 重定向到文件也要实时可见 */
    /* 种子混 PID：同秒启动的 seeder/getter 曾生成相同 peer_id，被 tracker
     * 当成同一 peer 去重——swarm 里就"没有别人"了（run.log 排错记） */
    srand((unsigned)time(NULL) ^ ((unsigned)GETPID() << 16));
    snprintf(my_peer_id, sizeof my_peer_id, "-PB0001-%012d", rand() % 1000000000);
    if (argc >= 4 && !strcmp(argv[1], "seed"))
        return seed_mode(argv[2], argv[3], argc > 4 ? atoi(argv[4]) : 12101);
    if (argc >= 4 && !strcmp(argv[1], "get"))
        return get_mode(argv[2], argv[3]);
    fprintf(stderr, "用法: %s seed <file.torrent> <数据文件> [端口] | get <file.torrent> "
                    "<输出文件>\n", argv[0]);
    net_cleanup();
    return 1;
}
