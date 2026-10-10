/* demo.c —— 迷你 Kademlia 常规实验：指数地址簿 · k 副本容错 · 50% churn 存活
 *
 * 构建运行：
 *   zig cc -o demo demo.c kad.c sha1.c && ./demo [节点数=48] [键数=40] [杀掉比例%=50]
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kad.h"

static int alive_count(void)
{
    int c = 0;
    for (int i = 0; i < kn; i++)
        c += knodes[i].alive;
    return c;
}

int main(int argc, char **argv)
{
    int N = argc > 1 ? atoi(argv[1]) : 48;
    int nkeys = argc > 2 ? atoi(argv[2]) : 40;
    int killpct = argc > 3 ? atoi(argv[3]) : 50;
    if (N < 8 || N > 200)
        N = 48;
    srand(7); /* 固定种子，run.log 可复现 */

    for (int i = 0; i < N; i++) {
        char name[32];
        snprintf(name, sizeof name, "kad-node-%d", i);
        kad_add_node(name, 0); /* 本实验不开 ID 门槛——女巫实验在 demo_sybil */
    }
    kad_bootstrap(0);
    printf("== 迷你 Kademlia：N=%d，k=%d，α=%d，160 位 XOR 空间 ==\n", kn, KAD_K,
           KAD_ALPHA);

    /* 1) 指数地址簿：挑一个节点看它的非空桶——越远的桶理论容量越大 */
    struct kad_node *me = &knodes[0];
    char hx[41];
    kad_hex(me->id, hx);
    printf("\n[k-bucket 体检] 节点0 id=%s…\n", hx);
    int used_buckets = 0, contacts = 0;
    for (int b = 0; b < BUCKETS; b++)
        if (me->bucket_len[b]) {
            used_buckets++;
            contacts += me->bucket_len[b];
            if (b >= BUCKETS - 8)
                printf("  桶 %3d（距离档 [2^%d,2^%d)）：占用 %d/%d\n", b, b, b + 1,
                       me->bucket_len[b], KAD_K);
        }
    printf("  …非空桶共 %d 个、联系人 %d 个（48 节点网络的合理体型）\n", used_buckets,
           contacts);

    /* 2) STORE：40 个键各写 k 份副本（迭代查找定位 K 近后逐个写入） */
    uint8_t keys[64][ID_BYTES];
    for (int i = 0; i < nkeys; i++) {
        char kw[32], val[32];
        snprintf(kw, sizeof kw, "key-%d", i);
        snprintf(val, sizeof val, "value-%d", i);
        kad_hash(kw, keys[i]);
        kad_store(rand() % kn, keys[i], val);
    }
    printf("\n[STORE] %d 个键 → 各 %d 份副本写入完成（迭代查找定位 K 近）\n", nkeys,
           KAD_K);

    /* 3) FIND_VALUE（健康网络） */
    int found = 0;
    int total_rpcs = 0;
    char val[64];
    for (int i = 0; i < nkeys; i++) {
        int rpcs = 0;
        found += kad_find_value(rand() % kn, keys[i], val, sizeof val, &rpcs);
        total_rpcs += rpcs;
    }
    printf("[FIND_VALUE 健康网络] %d/%d 命中，平均 %.1f 次 RPC/次\n", found, nkeys,
           (double)total_rpcs / nkeys);

    /* 4) churn：随机杀 killpct%，再找全部键——k 副本 + 迭代路径冗余的抗性 */
    int kills = kn * killpct / 100;
    for (int k = 0; k < kills; k++) {
        int idx;
        do {
            idx = rand() % kn;
        } while (!knodes[idx].alive);
        knodes[idx].alive = 0;
    }
    found = total_rpcs = 0;
    for (int i = 0; i < nkeys; i++) {
        int from;
        do {
            from = rand() % kn;
        } while (!knodes[from].alive);
        int rpcs = 0;
        found += kad_find_value(from, keys[i], val, sizeof val, &rpcs);
        total_rpcs += rpcs;
    }
    printf("[FIND_VALUE 杀 %d%% 节点后] %d/%d 命中，平均 %.1f 次 RPC/次（存活 %d 节点）\n",
           killpct, found, nkeys, (double)total_rpcs / nkeys, alive_count());
    printf("结论：单键 %d 份副本 + 查找路径本身冗余，让 DHT 对 churn 有天然容忍度；\n"
           "      丢键的本质是「某键的全部 K 近同时死亡」——概率随 k 指数下降。\n",
           KAD_K);
    return 0;
}
