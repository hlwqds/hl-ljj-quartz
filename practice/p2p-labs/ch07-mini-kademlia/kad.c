/* kad.c —— 迷你 Kademlia 引擎实现（配套 kad.h，算法语义对齐论文：
 * XOR 度量、指数 k-bucket、α 并发迭代查找、k 副本、FIND_VALUE 短路） */
#include "kad.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sha1.h"

struct kad_node knodes[MAX_NODES];
int kn = 0;
int kad_liar_from = -1; /* ≥0：从该索引起的节点在 FIND_NODE 应答里只报同伙
                           （索引投毒的"说谎"形态，ch10 §10.2） */

void kad_hash(const char *s, uint8_t out[ID_BYTES])
{
    sha1(s, strlen(s), out);
}

void kad_hex(const uint8_t id[ID_BYTES], char out[41])
{
    sha1_hex(id, out);
}

static int puzzle_pass(const uint8_t id[ID_BYTES], int bits) /* sha1(id) 前 bits 位为 0 */
{
    if (bits <= 0)
        return 1;
    uint8_t d[ID_BYTES];
    sha1(id, ID_BYTES, d);
    for (int i = 0; i < bits; i++) {
        int byte = i / 8, bit = 7 - i % 8;
        if (d[byte] & (1 << bit))
            return 0;
    }
    return 1;
}

static int id_eq(const uint8_t a[ID_BYTES], const uint8_t b[ID_BYTES])
{
    return !memcmp(a, b, ID_BYTES);
}

int kad_add_node_id(const uint8_t id[ID_BYTES], int puzzle_bits)
{
    if (kn >= MAX_NODES)
        return -1;
    for (int i = 0; i < kn; i++)
        if (id_eq(knodes[i].id, id))
            return -1;
    struct kad_node *n = &knodes[kn];
    memset(n, 0, sizeof *n);
    memcpy(n->id, id, ID_BYTES);
    n->alive = 1;
    n->puzzle_ok = puzzle_pass(id, puzzle_bits);
    return kn++;
}

int kad_add_node(const char *name, int puzzle_bits)
{
    uint8_t id[ID_BYTES];
    char salted[128];
    for (int tries = 0;; tries++) { /* 挖盐：直到 ID 本身通过网络门槛 */
        if (tries == 0)
            snprintf(salted, sizeof salted, "%s", name);
        else
            snprintf(salted, sizeof salted, "%s#%d", name, tries);
        kad_hash(salted, id);
        if (puzzle_pass(id, puzzle_bits))
            break;
    }
    return kad_add_node_id(id, puzzle_bits);
}

int kad_bucket_of(const uint8_t self[ID_BYTES], const uint8_t other[ID_BYTES])
{
    int b = 0;
    for (int i = 0; i < ID_BYTES; i++) {
        uint8_t x = self[i] ^ other[i];
        if (x)
            /* 字节内最高差异位：clz32(x)∈[24,31] → 位号 = 31-clz32(x)∈[0,7]。
               第一版写成 7-__builtin_clz(x)——clz 按 32 位整型计数，字节值 <0x80
               时结果为负、桶号全被丢弃（run.log 排错记）。 */
            return b + 31 - __builtin_clz((unsigned)x);
        b += 8;
    }
    return -1; /* 自身 */
}

int kad_closer(const uint8_t a[ID_BYTES], const uint8_t b[ID_BYTES],
               const uint8_t t[ID_BYTES])
{
    for (int i = 0; i < ID_BYTES; i++) {
        uint8_t xa = a[i] ^ t[i], xb = b[i] ^ t[i];
        if (xa != xb)
            return xa < xb;
    }
    return 0;
}

/* 学习联系人：进对应桶；桶满按"最老的先让位"（简化：挤掉队首，真实现先 ping）。
 * filter_bits>0：网络启用 ID 门槛，不合格 ID 的联系人拒收（女巫过滤）。 */
static void learn(struct kad_node *n, int ci, int filter_bits)
{
    if (&knodes[ci] == n)
        return;
    if (filter_bits > 0 && !puzzle_pass(knodes[ci].id, filter_bits))
        return;
    int b = kad_bucket_of(n->id, knodes[ci].id);
    if (b < 0)
        return;
    for (int i = 0; i < n->bucket_len[b]; i++)
        if (n->bucket[b][i] == ci)
            return;
    if (n->bucket_len[b] < KAD_K)
        n->bucket[b][n->bucket_len[b]++] = ci;
    else {
        memmove(n->bucket[b], n->bucket[b] + 1, sizeof(short) * (KAD_K - 1));
        n->bucket[b][KAD_K - 1] = ci;
    }
}

void kad_bootstrap(int enforce_bits)
{
    for (int i = 0; i < kn; i++) /* 应答即学习的对称红利：全对全 */
        for (int j = 0; j < kn; j++)
            learn(&knodes[i], j, enforce_bits);
}

int kad_rpc_find_node(int node, const uint8_t target[ID_BYTES], int out[KAD_K])
{
    /* 候选 = 自己 + 各桶联系人，按 XOR 距离取前 K（论文的 FIND_NODE 应答语义） */
    int cand[MAX_NODES], nc = 0;
    cand[nc++] = node;
    for (int b = 0; b < BUCKETS; b++)
        for (int i = 0; i < knodes[node].bucket_len[b]; i++)
            if (knodes[knodes[node].bucket[b][i]].alive)
                cand[nc++] = knodes[node].bucket[b][i];

    if (kad_liar_from >= 0 && node >= kad_liar_from) {
        int m = 0; /* 马甲应答只含同伙与它自己：把诚实节点从视野里抹掉 */
        for (int i = 0; i < nc; i++)
            if (cand[i] >= kad_liar_from || cand[i] == node)
                cand[m++] = cand[i];
        nc = m;
    }

    /* 简单选择排序取 K 近（演示规模 O(K·N) 足够） */
    int cnt = 0;
    int used[MAX_NODES] = { 0 };
    while (cnt < KAD_K && cnt < nc) {
        int best = -1;
        for (int i = 0; i < nc; i++)
            if (!used[i] && (best < 0 || kad_closer(knodes[cand[i]].id,
                                                    knodes[cand[best]].id, target)))
                best = i;
        used[best] = 1;
        out[cnt++] = cand[best];
    }
    return cnt;
}

int kad_iter_find_node(int from, const uint8_t target[ID_BYTES], int result[KAD_K],
                       int *rpcs)
{
    short seen[MAX_NODES] = { 0 }; /* shortlist 里出现过 */
    short queried[MAX_NODES] = { 0 };
    int list[MAX_NODES], nl = 0;

    int k0[KAD_K];
    int nk = kad_rpc_find_node(from, target, k0); /* 第 0 步：查自己的桶 */
    for (int i = 0; i < nk; i++)
        if (!seen[k0[i]]) {
            seen[k0[i]] = 1;
            list[nl++] = k0[i];
        }
    if (rpcs)
        *rpcs = 0;

    for (;;) {
        /* 取未查询的、活着的、离 target 最近的 α 个（α 路并发的串行模拟） */
        int alpha[KAD_ALPHA], na = 0;
        int chosen[MAX_NODES] = { 0 };
        while (na < KAD_ALPHA) {
            int best = -1;
            for (int i = 0; i < nl; i++) {
                int c = list[i];
                if (queried[c] || chosen[c] || !knodes[c].alive)
                    continue;
                if (best < 0 || kad_closer(knodes[c].id, knodes[best].id, target))
                    best = c;
            }
            if (best < 0)
                break;
            chosen[best] = 1;
            alpha[na++] = best;
        }
        if (na == 0)
            break; /* K 近全部问过：收敛 */

        for (int a = 0; a < na; a++) { /* 逐个发 FIND_NODE 并合并新联系人 */
            int c = alpha[a];
            queried[c] = 1;
            if (rpcs)
                (*rpcs)++;
            int kr[KAD_K];
            int nkr = kad_rpc_find_node(c, target, kr);
            for (int i = 0; i < nkr; i++)
                if (!seen[kr[i]]) {
                    seen[kr[i]] = 1;
                    list[nl++] = kr[i];
                }
        }
    }

    /* 结果：list 中活着的、离 target 最近的 K 个 */
    int cnt = 0;
    int taken[MAX_NODES] = { 0 };
    while (cnt < KAD_K) {
        int best = -1;
        for (int i = 0; i < nl; i++) {
            int c = list[i];
            if (taken[c] || !knodes[c].alive)
                continue;
            if (best < 0 || kad_closer(knodes[c].id, knodes[best].id, target))
                best = c;
        }
        if (best < 0)
            break;
        taken[best] = 1;
        result[cnt++] = best;
    }
    return cnt;
}

int kad_store(int from, const uint8_t key[ID_BYTES], const char *val)
{
    int k[KAD_K], rpcs;
    int nk = kad_iter_find_node(from, key, k, &rpcs);
    int copies = 0;
    for (int i = 0; i < nk; i++) {
        struct kad_node *n = &knodes[k[i]];
        int slot = -1;
        for (int s = 0; s < STORE_SLOTS; s++)
            if (!memcmp(n->store[s].key, key, ID_BYTES) || !n->store[s].val[0]) {
                slot = s;
                break;
            }
        if (slot >= 0) {
            memcpy(n->store[slot].key, key, ID_BYTES);
            snprintf(n->store[slot].val, sizeof n->store[0].val, "%s", val);
            copies++;
        }
    }
    return copies;
}

int kad_find_value(int from, const uint8_t key[ID_BYTES], char *val_out, size_t vsz,
                   int *rpcs)
{
    if (rpcs)
        *rpcs = 0;
    /* 短路语义：迭代途中问到的每个节点先查自己的 store，命中即返回 */
    for (int i = 0; i < kn; i++) { /* 用统一入口先自查（from 自己可能就有） */
        if (!knodes[i].alive || i != from)
            continue;
        for (int s = 0; s < STORE_SLOTS; s++)
            if (knodes[i].store[s].val[0] && !memcmp(knodes[i].store[s].key, key, ID_BYTES)) {
                snprintf(val_out, vsz, "%s", knodes[i].store[s].val);
                return 1;
            }
    }
    int k[KAD_K];
    int nk = kad_iter_find_node(from, key, k, rpcs);
    for (int i = 0; i < nk; i++) {
        struct kad_node *n = &knodes[k[i]];
        if (rpcs)
            (*rpcs)++; /* FIND_VALUE 也是一次 RPC */
        for (int s = 0; s < STORE_SLOTS; s++)
            if (n->store[s].val[0] && !memcmp(n->store[s].key, key, ID_BYTES)) {
                snprintf(val_out, vsz, "%s", n->store[s].val);
                return 1;
            }
    }
    return 0;
}
