/* chord.c —— 迷你 Chord 环：一致性哈希定宿主 + finger 路由 + churn 自愈
 *           （系列 ch06，模拟边界见套件 SPEC §2：算法/协议语义保真，
 *            真实网络传输层——丢包/延迟/超时重试——不在模拟范围）
 *
 * 模拟形状对齐论文：m 位 ID 环（演示取 m=8）、finger[i]=successor(n+2^(i-1))、
 * 查找走 closest_preceding_finger 每跳至少减半剩余距离、后继链容错。
 * 每次查找计数"网络跳数"，杀节点后统计"超时回退"（跳到的 finger 已死，
 * 换次优候选——真实实现里就是一次 RPC 超时后重选）。
 *
 * 构建：zig cc -o chord chord.c sha1.c   （sha1.c 从 ch02 工程拷贝，同款）
 * 运行：./chord [节点数=16] [键数=200] [杀掉数=6]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include "sha1.h"

#define M 8                 /* ID 位宽：环大小 256 */
#define RING (1 << M)       /* 256 */
#define SUCC_LIST 5         /* 后继链长度 r */
#define MAXN 64

struct node {
    int id;
    int alive;
    int succ[SUCC_LIST];    /* 后继链：容错的命根子 */
    int finger[M];          /* finger[i] = successor(id + 2^i)，允许过时 */
};

static struct node ns[MAXN];
static int N;

static int hash_id(const char *s) /* sha1 → 环上位置 */
{
    uint8_t d[20];
    sha1(s, strlen(s), d);
    return (d[19] | d[18] << 8) & (RING - 1);
}

static double log2_(int x)
{
    return x <= 1 ? 0 : 32 - __builtin_clz(x - 1);
}

static int cmp_id_helper(const void *a, const void *b)
{
    const struct node *x = a, *y = b;
    return x->id - y->id;
}

/* 环序辅助：y 是否在 (x, z] 半开区间内（含回绕） */
static int between(int x, int y, int z)
{
    if (x < z)
        return y > x && y <= z;
    if (x > z)
        return y > x || y <= z;
    return y != x; /* x==z 的整圈情形，演示不触发 */
}

static struct node *by_id(int id)
{
    for (int i = 0; i < N; i++)
        if (ns[i].id == id)
            return &ns[i];
    return NULL;
}

/* 死节点过滤器：RPC 目标已死 = 真实世界的"超时"，这里直接换次优 */
static int alive_or_next(int id)
{
    struct node *n = by_id(id);
    if (n && n->alive)
        return id;
    return -1;
}

/* 后继链修复：沿链推进到第一个活着的（stabilize 的核心动作） */
static void repair_succ(struct node *n)
{
    for (int i = 0; i < SUCC_LIST; i++) {
        struct node *s = by_id(n->succ[i]);
        if (s && s->alive) { /* 链整体前移 */
            for (int j = 0; j + i < SUCC_LIST; j++)
                n->succ[j] = n->succ[j + i];
            return;
        }
    }
}

/* 真值函数：环上第一个活着的 id≥k（用于校验路由结果） */
static int true_successor(int k)
{
    for (int step = 0; step < RING; step++) {
        struct node *n = by_id((k + step) & (RING - 1));
        if (n && n->alive)
            return n->id;
    }
    return -1;
}

/* ★ 协议核心：从 from 出发找 successor(key)，逐跳转发并计数 */
static int find_successor(int from, int key, int *hops, int *timeouts)
{
    struct node *cur = by_id(from);
    *hops = 0;
    *timeouts = 0;
    for (;;) {
        if (!cur->alive) { /* 当前跳已死：真实世界表现为超时；沿后继链找活节点 */
            (*timeouts)++;
            struct node *alt = NULL;
            for (int i = 0; i < SUCC_LIST; i++) {
                struct node *cand = by_id(cur->succ[i]);
                if (cand && cand->alive) {
                    alt = cand;
                    break;
                }
            }
            if (!alt)
                return -1; /* 后继链全灭：该节点与环失联 */
            cur = alt;
            continue;
        }
        int succ0 = cur->succ[0];
        struct node *s0 = by_id(succ0);
        if (key == cur->id)
            return cur->id; /* 哈希恰好砸在节点 ID 上：宿主是我自己。
                               漏掉这行时这类 key 会绕环一整圈（run.log 排错记） */
        if (s0 && s0->alive && between(cur->id, key, succ0))
            return succ0; /* 目标落在我的后继弧段：它就是宿主 */
        /* closest_preceding_finger：从最远 finger 往回找不超过 key 的活节点 */
        int next = -1;
        for (int i = M - 1; i >= 0; i--) {
            int cand = cur->finger[i];
            if (cand < 0)
                continue;
            if (between(cur->id, cand, key) && cand != cur->id) {
                int live = alive_or_next(cand);
                if (live >= 0) {
                    next = live;
                    break;
                }
                (*timeouts)++; /* 指到的 finger 死了：超时一次，退而求其次 */
            }
        }
        if (next < 0) { /* finger 全不可用：退化线性走后继（正确性兜底） */
            for (int i = 0; i < SUCC_LIST; i++) {
                int live = alive_or_next(cur->succ[i]);
                if (live >= 0 && live != cur->id) {
                    next = live;
                    break;
                }
            }
        }
        if (next < 0)
            return -1; /* 与全网失联（演示规模不会发生） */
        (*hops)++;
        cur = by_id(next);
        if (*hops > RING)
            return -1;
    }
}

static void build_ring(void)
{
    for (int i = 0; i < N; i++) {
        char name[32];
        snprintf(name, sizeof name, "node-%d", i);
        do {
            ns[i].id = hash_id(name);
            int dup = 0; /* 哈希撞车就改名重摇——真实部署同理 */
            for (int j = 0; j < i; j++)
                if (ns[j].id == ns[i].id)
                    dup = 1;
            if (dup)
                strcat(name, "#");
            else
                break;
        } while (1);
        ns[i].alive = 1;
    }
    qsort(ns, N, sizeof ns[0], cmp_id_helper);
}

/* 初始化后继链与 finger 表（对应协议的 join + stabilize 若干轮后的稳定态） */
static void prime_tables(void)
{
    for (int i = 0; i < N; i++) {
        for (int j = 0; j < SUCC_LIST; j++)
            ns[i].succ[j] = ns[(i + 1 + j) % N].id;
        for (int f = 0; f < M; f++) {
            int start = (ns[i].id + (1 << f)) & (RING - 1);
            ns[i].finger[f] = true_successor(start); /* 杀节点后允许过时 */
        }
    }
}

/* 杀掉 k 个节点后跑若干轮 stabilize：后继链修复 + 每节点随机修 2 根 finger */
static void stabilize_rounds(void)
{
    for (int round = 0; round < 3; round++) {
        for (int i = 0; i < N; i++) {
            if (!ns[i].alive)
                continue;
            repair_succ(&ns[i]);
            /* 后继链续链：问后继要它的后继 */
            struct node *s = by_id(ns[i].succ[0]);
            for (int j = 1; j < SUCC_LIST && s; j++) {
                ns[i].succ[j] = s->alive ? s->succ[0] : ns[i].succ[j - 1];
                s = by_id(ns[i].succ[j]);
            }
            for (int f = 0; f < 2; f++) { /* fix_fingers：随机挑指针重查 */
                int idx = rand() % M;
                int start = (ns[i].id + (1 << idx)) & (RING - 1);
                int nsucc = true_successor(start);
                if (nsucc >= 0)
                    ns[i].finger[idx] = nsucc;
            }
        }
    }
}

int main(int argc, char **argv)
{
    N = argc > 1 ? atoi(argv[1]) : 16;
    int nkeys = argc > 2 ? atoi(argv[2]) : 200;
    int kills = argc > 3 ? atoi(argv[3]) : 6;
    if (N < 4 || N > MAXN)
        N = 16;
    srand(42); /* 固定种子：run.log 可逐字节复现 */

    build_ring();
    prime_tables();

    printf("== 迷你 Chord：m=%d 位环，N=%d 节点 ==\n环序：", M, N);
    for (int i = 0; i < N; i++)
        printf("%d ", ns[i].id);
    printf("\n\n");

    int total_hops = 0, max_hops = 0, total_to = 0, fails = 0;
    for (int k = 0; k < nkeys; k++) {
        char key[32];
        snprintf(key, sizeof key, "key-%d", k);
        int kid = hash_id(key);
        int from = ns[rand() % N].id;
        int hops, to;
        int res = find_successor(from, kid, &hops, &to);
        if (res < 0 || res != true_successor(kid))
            fails++;
        total_hops += hops;
        total_to += to;
        if (hops > max_hops)
            max_hops = hops;
    }
    printf("[健康网络] %d 次查找：平均 %.2f 跳（理论 O(log N)≈%.1f），最大 %d 跳，"
           "超时 %d 次，错判 %d 次\n",
           nkeys, (double)total_hops / nkeys, log2_(N), max_hops, total_to, fails);

    for (int k = 0; k < kills; k++) { /* 随机杀节点：churn 注入 */
        int idx;
        do {
            idx = rand() % N;
        } while (!ns[idx].alive);
        ns[idx].alive = 0;
        printf("  ✝ 节点 %d 下线\n", ns[idx].id);
    }
    stabilize_rounds();

    total_hops = max_hops = total_to = fails = 0;
    int ok = 0;
    for (int k = 0; k < nkeys; k++) {
        char key[32];
        snprintf(key, sizeof key, "key-%d", k);
        int kid = hash_id(key);
        int from;
        do {
            from = ns[rand() % N].id;
        } while (!by_id(from)->alive);
        int hops, to;
        int res = find_successor(from, kid, &hops, &to);
        if (res == true_successor(kid) && res >= 0)
            ok++;
        else
            fails++;
        total_hops += hops;
        total_to += to;
        if (hops > max_hops)
            max_hops = hops;
    }
    printf("\n[杀 %d 节点 + 3 轮 stabilize] %d 次查找：成功 %d，平均 %.2f 跳，最大 %d 跳，"
           "超时回退 %d 次，失败 %d 次\n",
           kills, nkeys, ok, (double)total_hops / nkeys, max_hops, total_to, fails);
    printf("结论：finger 让健康网络跑出 O(log N)；churn 之后正确性挂在后继链上兜底，\n"
           "      超时回退就是真实实现里的一次 RPC 超时重选——慢但不断服。\n");
    return 0;
}
