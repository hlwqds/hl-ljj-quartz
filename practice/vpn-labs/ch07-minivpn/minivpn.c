/* minivpn.c —— mini-VPN 双端：TUN × 安全信封（系列 ch07 总装）
 *
 * 数据通路：应用 → 路由表 → tun0 → read() 裸 IP 包 → ChaCha20+HMAC 封帧
 *           → UDP → 对端验章/查窗/解密 → write() 注回对端 tun0。
 * 密钥文件 64B：[0..31] 加密钥，[32..63] MAC 钥（ch06 的 KDF 产物或 urandom）。
 * 方向隔离：nonce 魔数含本端角色（--role a|b）——两端角色必须互异，
 *           否则 (key,nonce) 撞车 = ch04 §4.4 的密钥流复用事故。
 *
 * 模式：
 *   双端：  ./minivpn --tun tun0 --key vpn.key --role a --addr 10.7.0.1 \
 *              --peer <对端公网:51820> --port 51820
 *   --loopback   自环自检：封帧→解帧逐字节比对（不需要对端与 root）
 *   --hexdump    TUN 观察器：打印每个入 TUN 的 IP 包头字段（ch03 实验）
 *
 * 构建（Linux）：zig cc -O2 -o minivpn minivpn.c chacha20.c sha256.c hmac.c
 * 本仓入库形态：zig cc --target x86_64-linux 交叉编译验证（SPEC §2 诚实性规则）。
 * tun0 的地址/MTU/路由用系统命令配置（README 有清单），程序只管隧道两端。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <linux/if_tun.h>

#include "chacha20.h"
#include "hmac.h"
#include "sha256.h"

#define WINDOW 64
#define KEEPALIVE_SEC 10
#define MTU 2000 /* 读 TUN 的缓冲上限（tun0 建议 MTU 1420，见 README） */

static uint8_t ENC_KEY[32], MAC_KEY[32];
static char ROLE;
static uint8_t NONCE_MAGIC[4] = { 'M', 'V', 'P', 0 };

/* ---------- TUN ---------- */

static int tun_open(const char *name)
{
    int fd = open("/dev/net/tun", O_RDWR);
    if (fd < 0) {
        perror("open /dev/net/tun（需要 root 与 tun 模块）");
        return -1;
    }
    struct ifreq ifr = { 0 };
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI; /* L3 设备，无 4B 包信息前缀 */
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);
    if (ioctl(fd, TUNSETIFF, &ifr) < 0) {
        perror("TUNSETIFF");
        close(fd);
        return -1;
    }
    printf("[tun] %s 已就绪（IFF_TUN|IFF_NO_PI）\n", ifr.ifr_name);
    return fd;
}

/* ---------- 安全信封（与 ch05 secure.c 同构：[ctr8][ct][tag32]） ---------- */

static void put64(uint8_t *p, uint64_t v)
{
    for (int i = 0; i < 8; i++)
        p[i] = (uint8_t)(v >> (56 - 8 * i));
}
static uint64_t get64(const uint8_t *p)
{
    uint64_t v = 0;
    for (int i = 0; i < 8; i++)
        v = v << 8 | p[i];
    return v;
}
static int ct_memcmp(const uint8_t *a, const uint8_t *b, size_t n)
{
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++)
        d |= a[i] ^ b[i];
    return d != 0;
}

static void seal(uint64_t ctr, const uint8_t *pt, size_t plen, uint8_t *frame, size_t *flen)
{
    uint8_t nonce[12], ct[MTU];
    memcpy(nonce, NONCE_MAGIC, 3);
    nonce[3] = (uint8_t)ROLE; /* 方向隔离：本端角色进 nonce */
    put64(nonce + 4, ctr);
    chacha20_xor(ENC_KEY, nonce, 0, pt, ct, plen);

    put64(frame, ctr);
    memcpy(frame + 8, ct, plen);
    uint8_t macin[8 + MTU];
    memcpy(macin, frame, 8);
    memcpy(macin + 8, ct, plen);
    hmac_sha256(MAC_KEY, 32, macin, 8 + plen, frame + 8 + plen);
    *flen = 8 + plen + 32;
}

struct rx {
    uint64_t highest, bitmap;
};

static int unseal(struct rx *rx, uint8_t peer_role, const uint8_t *frame, size_t flen,
                  uint8_t *pt, size_t *plen)
{
    uint64_t ctr = get64(frame);
    size_t clen = flen - 8 - 32;

    uint8_t tag[32], macin[8 + MTU];
    memcpy(macin, frame, 8);
    memcpy(macin + 8, frame + 8, clen);
    hmac_sha256(MAC_KEY, 32, macin, 8 + clen, tag);
    if (ct_memcmp(tag, frame + 8 + clen, 32)) {
        printf("[sec] ctr=%llu MAC 失败，丢帧\n", (unsigned long long)ctr);
        return -1;
    }
    if (ctr > rx->highest) {
        uint64_t shift = ctr - rx->highest;
        rx->bitmap = shift >= WINDOW ? 0 : (rx->bitmap << shift);
        rx->bitmap |= 1;
        rx->highest = ctr;
    } else {
        uint64_t left = rx->highest >= WINDOW - 1 ? rx->highest - (WINDOW - 1) : 0;
        if (ctr < left) {
            printf("[sec] ctr=%llu 窗口外旧帧，丢\n", (unsigned long long)ctr);
            return -1;
        }
        uint64_t bit = 1ull << (rx->highest - ctr);
        if (rx->bitmap & bit) {
            printf("[sec] ctr=%llu 重放，丢\n", (unsigned long long)ctr);
            return -1;
        }
        rx->bitmap |= bit;
    }
    uint8_t nonce[12];
    memcpy(nonce, NONCE_MAGIC, 3);
    nonce[3] = peer_role;
    put64(nonce + 4, ctr);
    chacha20_xor(ENC_KEY, nonce, 0, frame + 8, pt, clen);
    *plen = clen;
    return 0;
}

/* ---------- 观察器 ---------- */

static void ip_hexdump(const uint8_t *p, int n)
{
    if (n < 20) {
        printf("[hexdump] 短包 %dB\n", n);
        return;
    }
    uint16_t total = p[2] << 8 | p[3];
    uint8_t proto = p[9];
    char src[16], dst[16];
    snprintf(src, sizeof src, "%u.%u.%u.%u", p[12], p[13], p[14], p[15]);
    snprintf(dst, sizeof dst, "%u.%u.%u.%u", p[16], p[17], p[18], p[19]);
    printf("[hexdump] %dB v%u ihl=%u proto=%u(%s) %s → %s\n", n, p[0] >> 4, p[0] & 15,
           proto, proto == 1 ? "ICMP" : proto == 6 ? "TCP" : proto == 17 ? "UDP" : "?",
           src, dst);
}

/* ---------- 自环自检（不需要 root/TUN/对端） ---------- */

static int loopback_test(void)
{
    uint8_t pkt[64];
    for (int i = 0; i < 64; i++)
        pkt[i] = (uint8_t)(i * 7);
    pkt[0] = 0x45;
    uint8_t frame[1600], out[1600];
    size_t flen, olen;
    struct rx rx = { 0, 0 };
    uint64_t ctr = 1;
    int ok = 1;

    for (int i = 0; i < 3; i++) { /* 三帧自环：顺序 + 乱序 */
        seal(ctr + (i == 2 ? 2 : i), pkt, sizeof pkt, frame, &flen);
        if (unseal(&rx, 'a', frame, flen, out, &olen) == 0 && olen == sizeof pkt &&
            !memcmp(out, pkt, sizeof pkt))
            printf("[loopback] 帧 %d：封帧→解帧 逐字节一致 ✓\n", i + 1);
        else
            ok = 0, printf("[loopback] 帧 %d：不一致 ✗\n", i + 1);
        ctr += 2;
    }
    seal(1, pkt, sizeof pkt, frame, &flen); /* 重放第一帧 */
    printf("[loopback] 重放旧帧：%s（预期拒收）\n",
           unseal(&rx, 'a', frame, flen, out, &olen) == 0 ? "收下 ✗" : "拒收 ✓");
    return ok ? 0 : 1;
}

/* ---------- 主程序 ---------- */

int main(int argc, char **argv)
{
    const char *tun_name = "tun0", *key_file = NULL, *peer_s = NULL, *role_s = "a";
    int port = 51820, hexdump = 0, loopback = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--tun") && i + 1 < argc)
            tun_name = argv[++i];
        else if (!strcmp(argv[i], "--key") && i + 1 < argc)
            key_file = argv[++i];
        else if (!strcmp(argv[i], "--peer") && i + 1 < argc)
            peer_s = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc)
            port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--role") && i + 1 < argc)
            role_s = argv[++i];
        else if (!strcmp(argv[i], "--hexdump"))
            hexdump = 1;
        else if (!strcmp(argv[i], "--loopback"))
            loopback = 1;
    }
    ROLE = role_s[0];

    if (loopback) { /* 密钥也可缺席：用固定演示钥跑自检 */
        if (key_file) {
            FILE *f = fopen(key_file, "rb");
            if (!f || fread(ENC_KEY, 1, 32, f) != 32 || fread(MAC_KEY, 1, 32, f) != 32) {
                perror("key file（需 64B）");
                return 1;
            }
            fclose(f);
        } else {
            memcpy(ENC_KEY, "0123456789abcdef0123456789abcdef", 32);
            memcpy(MAC_KEY, "fedcba9876543210fedcba9876543210", 32);
        }
        return loopback_test();
    }

    if (!key_file || !peer_s) {
        fprintf(stderr,
                "用法: %s --key <64B钥文件> --peer <对端IP:端口> [--tun tun0] "
                "[--port 51820] [--role a|b] | --loopback | --hexdump --key <钥>\n",
                argv[0]);
        return 1;
    }
    FILE *f = fopen(key_file, "rb");
    if (!f || fread(ENC_KEY, 1, 32, f) != 32 || fread(MAC_KEY, 1, 32, f) != 32) {
        perror("key file（需 64B：前 32B 加密钥 + 后 32B MAC 钥）");
        return 1;
    }
    fclose(f);

    int tun_fd = tun_open(tun_name);
    if (tun_fd < 0)
        return 1;

    char peer_ip[64] = "127.0.0.1";
    int peer_port = port;
    char *colon = strrchr(peer_s, ':');
    if (colon && colon[1] >= '0' && colon[1] <= '9') {
        snprintf(peer_ip, sizeof peer_ip, "%.*s", (int)(colon - peer_s), peer_s);
        peer_port = atoi(colon + 1);
    }
    int udp = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = { 0 }, peer = { 0 };
    me.sin_family = peer.sin_family = AF_INET;
    me.sin_addr.s_addr = peer.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    peer.sin_port = htons((unsigned short)peer_port);
    peer.sin_addr.s_addr = inet_addr(peer_ip);
    if (bind(udp, (struct sockaddr *)&me, sizeof me) < 0) {
        perror("bind");
        return 1;
    }
    uint8_t peer_role = ROLE == 'a' ? 'b' : 'a';
    printf("[net] UDP :%d ⇄ %s:%d（对端角色 %c，密钥流方向隔离）\n", port, peer_ip,
           peer_port, peer_role);

    if (hexdump) { /* ch03 观察器：打印每个进 TUN 的包 */
        uint8_t buf[MTU];
        printf("[hexdump] 模式：等包中（另开终端 ping 对端隧道地址）\n");
        for (;;) {
            int n = (int)read(tun_fd, buf, sizeof buf);
            if (n <= 0)
                break;
            ip_hexdump(buf, n);
        }
        return 0;
    }

    uint64_t send_ctr = 1;
    struct rx rx = { 0, 0 };
    long sent_pkts = 0, recv_pkts = 0;
    time_t last_ka = time(NULL);
    printf("[vpn] 隧道就绪（角色 %c）。系统侧配置见 README：ip addr/route/mtu。\n", ROLE);

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(tun_fd, &rfds);
        FD_SET(udp, &rfds);
        struct timeval tv = { 1, 0 };
        int r = select(tun_fd > udp ? tun_fd + 1 : udp + 1, &rfds, NULL, NULL, &tv);
        (void)r;

        if (FD_ISSET(tun_fd, &rfds)) { /* TUN → 加密封装 → 对端 */
            uint8_t pkt[MTU], frame[8 + MTU + 32];
            int n = (int)read(tun_fd, pkt, sizeof pkt);
            if (n > 0) {
                size_t flen;
                seal(send_ctr++, pkt, (size_t)n, frame, &flen);
                sendto(udp, frame, (int)flen, 0, (struct sockaddr *)&peer, sizeof peer);
                if (++sent_pkts % 100 == 0)
                    printf("[vpn] 已发 %ld 包（ctr=%llu）\n", sent_pkts,
                           (unsigned long long)(send_ctr - 1));
            }
        }
        if (FD_ISSET(udp, &rfds)) { /* 对端 → 验章/查窗/解密 → TUN */
            uint8_t frame[8 + MTU + 32], pkt[MTU];
            socklen_t fl = sizeof peer;
            int n = (int)recvfrom(udp, frame, sizeof frame, 0, (struct sockaddr *)&peer,
                                  &fl);
            size_t plen;
            if (n > 40 && unseal(&rx, peer_role, frame, (size_t)n, pkt, &plen) == 0) {
                if (plen > 0) {
                    if (write(tun_fd, pkt, plen) < 0)
                        perror("write tun");
                    recv_pkts++;
                }
                /* recvfrom 已顺带刷新 peer 地址：合法密钥的包来自哪，对端就在哪
                   ——WireGuard roaming 的同款思想（ch09 §9.6） */
            }
        }
        if (time(NULL) - last_ka >= KEEPALIVE_SEC) { /* 保活 + NAT 维持 */
            uint8_t frame[8 + 32];
            size_t flen;
            seal(send_ctr++, (const uint8_t *)"", 0, frame, &flen);
            sendto(udp, frame, (int)flen, 0, (struct sockaddr *)&peer, sizeof peer);
            last_ka = time(NULL);
        }
    }
}
