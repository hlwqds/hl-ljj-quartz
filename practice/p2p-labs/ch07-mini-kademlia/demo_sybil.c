/* demo_sybil.c —— 女巫攻击与「让身份变贵」的防御（系列 ch10 §10.1/§10.3 的实验形态）
 *
 * 三幕剧（同一份引擎 kad.c）：
 *   第一幕：40 个诚实节点 + 键 crown-jewel，正常存取；
 *   第二幕：攻击者注册 60 个 ID 被精确钉在目标键附近的马甲（零成本入场），
 *           无防御网络里目标键的 K 近全被马甲占领——FIND_VALUE 被日蚀；
 *   第三幕：全网启用 S/Kademlia 式 ID 门槛（sha1(id) 前 8 位为 0）：
 *           诚实节点挖盐入场、学习时过滤不合格联系人，马甲进不了桶 →
 *           查找恢复；代价透明：攻击者的入场费从 0 变成 2^8 次/个。
 *
 * 构建运行：zig cc -o demo_sybil demo_sybil.c kad.c sha1.c && ./demo_sybil
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kad.h"

#define PUZZLE_BITS 8  /* ID 门槛：sha1(id) 前 8 位为 0，平均挖 256 次/ID */
#define HONEST_N 40
#define SYBIL_N 60

static uint8_t target[ID_BYTES];
static int honest_n = HONEST_N; /* 前段索引 = 诚实节点，后段 = 马甲 */

static void reset_network(int honest_puzzle_bits, int sybils, int filter_bits)
{
    kn = 0;
    for (int i = 0; i < HONEST_N; i++) { /* 诚实节点：付挖盐成本拿合格 ID */
        char name[32];
        snprintf(name, sizeof name, "honest-%d", i);
        kad_add_node(name, honest_puzzle_bits);
    }
    honest_n = kn;
    for (int i = 0; i < sybils; i++) { /* 马甲：ID 直接钉在 target 附近，不挖盐 */
        uint8_t id[ID_BYTES];
        memcpy(id, target, ID_BYTES);
        id[19] ^= (uint8_t)(i + 1); /* 与 target 只差最后 1 字节：XOR 距离极近 */
        kad_add_node_id(id, 0);
    }
    kad_bootstrap(filter_bits);
}

static int probe(const char *tag)
{
    char val[64];
    int rpcs = 0;
    int from = rand() % honest_n; /* 从随机诚实节点发起（马甲不持有数据） */
    int ok = kad_find_value(from, target, val, sizeof val, &rpcs);
    printf("%s FIND_VALUE(crown-jewel) → %s（%d 次 RPC）\n", tag,
           ok ? val : "❌ 未找到", rpcs);
    return ok;
}

int main(void)
{
    srand(7);
    kad_hash("crown-jewel", target);
    char hx[41];
    kad_hex(target, hx);

    printf("== 第一幕：诚实网络（%d 节点，无攻击面）==\n", HONEST_N);
    reset_network(0, 0, 0);
    printf("  目标键 crown-jewel → %s…\n", hx);
    int copies = kad_store(0, target, "the-crown-jewel");
    printf("  STORE 成功写入 %d/%d 份副本\n", copies, KAD_K);
    probe(" ");

    printf("\n== 第二幕：%d 个马甲钉到目标键邻域 + 说谎应答（网络不验 ID 门槛）==\n",
           SYBIL_N);
    reset_network(0, SYBIL_N, 0); /* 无防御：不挖盐、不过滤 */
    kad_liar_from = honest_n;     /* 马甲的 FIND_NODE 应答只报同伙：索引投毒 */
    kad_store(0, target, "the-crown-jewel");
    probe(" "); /* 旧副本仍可能救场：见下方解读 */
    int k[KAD_K], rpcs;
    int nk = kad_iter_find_node(0, target, k, &rpcs);
    printf("  目标键的 %d 近此刻为：", nk);
    for (int i = 0; i < nk; i++)
        printf("%s ", k[i] < honest_n ? "honest" : "马甲");
    printf("——K 近已被占领\n");

    /* 真正的杀伤在写路径：DHT 周期性 republish 会把手里的键迁往「当前 K 近」——
     * 日蚀之下那正是马甲。模拟一次刷新：同一键再 STORE，看新副本落进谁手里。 */
    kad_store(0, target, "crown-jewel-v2");
    int on_sybil = 0;
    for (int i = honest_n; i < kn; i++)
        for (int s = 0; s < STORE_SLOTS; s++)
            if (knodes[i].store[s].val[0] && !memcmp(knodes[i].store[s].key, target, ID_BYTES))
                on_sybil++;
    printf("  刷新再发布后，落在马甲手里的副本：%d/%d——写路径被劫持。\n"
           "  旧值此刻还能查到（既有副本救场），但副本持有者也在按 K 近刷新，\n"
           "  迁移完成后数据与索引彻底归攻击者接管——这就是日蚀的完整含义。\n",
           on_sybil, KAD_K);

    printf("\n== 第三幕：同样 %d 个马甲，全网启用 %d 位 ID 门槛 ==\n", SYBIL_N,
           PUZZLE_BITS);
    kad_liar_from = -1;
    reset_network(PUZZLE_BITS, SYBIL_N, PUZZLE_BITS); /* 诚实挖盐入场，学习端过滤 */
    kad_store(0, target, "the-crown-jewel");
    probe(" ");
    nk = kad_iter_find_node(0, target, k, &rpcs);
    printf("  目标键的 %d 近此刻为：", nk);
    for (int i = 0; i < nk; i++)
        printf("%s ", k[i] < honest_n ? "honest" : "马甲");
    printf("——门槛把马甲挡在桶外\n");
    printf("  代价对账：每个诚实 ID 平均挖 2^%d=%d 次哈希才合格；\n"
           "  攻击者想钉一个马甲进目标邻域，同样得付 2^%d 次/个——%d 个马甲的入场费"
           "从 0 涨到 ~%d 次哈希。\n"
           "  ch10 的结论落地：女巫防御的本质是给身份定价（PoW 的微缩版）。\n",
           PUZZLE_BITS, 1 << PUZZLE_BITS, PUZZLE_BITS, SYBIL_N,
           SYBIL_N * (1 << PUZZLE_BITS));
    return 0;
}
