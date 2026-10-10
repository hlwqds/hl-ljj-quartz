/* rendezvous.c —— 打洞引路服务器（系列 ch04 §4.1 的 S 角色）
 *
 * 职责严格限定在"情报交换"（控制面）：登记两个端点、把彼此的观测地址
 * （公网环境下就是各自 NAT 的映射端点）发给对方，然后退场——数据一个
 * 字节不转发。协议三条文本报文：
 *   REG  <room> <name>\n    端点登记（重复发送用于重试）
 *   ACK\n                   登记确认
 *   PEER <name> <ip> <port>\n  配对完成，告知对方的观测地址（发给双方）
 *
 * 用法：./rendezvous [端口=12050]
 */
#include "net_compat.h"

#define MAX_ROOMS 16

struct slot {
    int used;
    char room[32], name[32];
    struct sockaddr_in addr;
};

int main(int argc, char **argv)
{
    int port = argc > 1 ? atoi(argv[1]) : 12050;
    net_init();
    setvbuf(stdout, NULL, _IONBF, 0);
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in me = { 0 };
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = INADDR_ANY;
    me.sin_port = htons((unsigned short)port);
    bind(s, (struct sockaddr *)&me, sizeof me);
    printf("引路服务器 :%d 就绪（只换情报，不转数据）\n", port);

    struct slot slots[MAX_ROOMS] = { 0 };
    char buf[256];
    for (;;) {
        struct sockaddr_in from;
        socklen_t fl = sizeof from;
        int n = recvfrom(s, buf, sizeof buf - 1, 0, (struct sockaddr *)&from, &fl);
        if (n <= 0)
            continue;
        buf[n] = 0;
        char cmd[16], room[32], name[32];
        if (sscanf(buf, "%15s %31s %31s", cmd, room, name) != 3 || strcmp(cmd, "REG"))
            continue;

        /* 已登记过（同名同房间）就刷新地址；否则找空位入座 */
        struct slot *mine = NULL, *other = NULL;
        for (int i = 0; i < MAX_ROOMS; i++) {
            if (!slots[i].used)
                continue;
            if (slots[i].used == 1 && !strcmp(slots[i].room, room)) {
                if (!strcmp(slots[i].name, name))
                    mine = &slots[i];
                else
                    other = &slots[i];
            }
        }
        if (!mine) {
            for (int i = 0; i < MAX_ROOMS; i++)
                if (!slots[i].used) {
                    mine = &slots[i];
                    break;
                }
        }
        if (!mine)
            continue;
        mine->used = 1;
        snprintf(mine->room, sizeof mine->room, "%s", room);
        snprintf(mine->name, sizeof mine->name, "%s", name);
        mine->addr = from;

        char ack[8] = "ACK\n";
        sendto(s, ack, 4, 0, (struct sockaddr *)&from, fl);
        printf("REG %-8s room=%-10s 观测地址 %s:%u\n", name, room,
               inet_ntoa(from.sin_addr), ntohs(from.sin_port));

        if (other) { /* 房间满员：向双方互发情报，打洞随即开始 */
            char info[96], info2[96];
            snprintf(info, sizeof info, "PEER %s %s %u\n", other->name,
                     inet_ntoa(other->addr.sin_addr), ntohs(other->addr.sin_port));
            sendto(s, info, (int)strlen(info), 0, (struct sockaddr *)&from, fl);
            snprintf(info2, sizeof info2, "PEER %s %s %u\n", mine->name,
                     inet_ntoa(mine->addr.sin_addr), ntohs(mine->addr.sin_port));
            sendto(s, info2, (int)strlen(info2), 0, (struct sockaddr *)&other->addr,
                   sizeof other->addr);
            printf("配对 %s ⇄ %s，情报已互发，本服务器功成身退\n", other->name, mine->name);
            other->used = 0; /* 清空房间，供下一对复用 */
            mine->used = 0;
        }
    }
}
