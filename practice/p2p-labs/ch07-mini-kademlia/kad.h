/* kad.h —— 迷你 Kademlia 引擎接口（系列 ch07/ch10；模拟边界见套件 SPEC §2）
 *
 * 对齐论文的语义：160 位 ID、XOR 度量、k-bucket 指数分桶、四动词里的
 * PING 略去（模拟中无延迟无丢包）、FIND_NODE / FIND_VALUE / STORE 保留。
 * 节点是进程内对象，"一次 RPC" = 一次函数调用 + rpc 计数。
 */
#ifndef KAD_H
#define KAD_H

#include <stdint.h>
#include <stddef.h>

#define ID_BYTES 20
#define KAD_K 4
#define KAD_ALPHA 3
#define MAX_NODES 512
#define BUCKETS (ID_BYTES * 8)
#define STORE_SLOTS 24

struct kad_node {
    uint8_t id[ID_BYTES];
    int alive;
    int puzzle_ok; /* ID 通过网络的工作量门槛（S/Kademlia 式女巫抵抗，ch10） */
    short bucket[BUCKETS][KAD_K]; /* 桶 i：与我的 XOR 距离在 [2^i, 2^(i+1)) */
    int bucket_len[BUCKETS];
    struct {
        uint8_t key[ID_BYTES];
        char val[64];
    } store[STORE_SLOTS];
};

extern struct kad_node knodes[MAX_NODES];
extern int kn;
extern int kad_liar_from; /* ≥0：该索引起的节点是"说谎马甲"（应答只报同伙） */

void kad_hash(const char *s, uint8_t out[ID_BYTES]);
/* 注册节点：name 哈希成 ID；puzzle_bits>0 时挖盐直到 sha1(id) 前 N 位为 0 */
int kad_add_node(const char *name, int puzzle_bits);
/* 指定 ID 注册（攻击者用：把 ID 钉在目标附近）；puzzle_bits 同上可为 0 */
int kad_add_node_id(const uint8_t id[ID_BYTES], int puzzle_bits);
/* 入网学习：全对全交换联系人（真实协议是逐 join 迭代；模拟取稳定态捷径）。
 * enforce_bits>0 时按网络门槛过滤：sha1(联系人ID) 前 N 位非 0 的不进桶
 * （S/Kademlia 式女巫抵抗——门槛属于网络，不属于单个节点的自觉）。 */
void kad_bootstrap(int enforce_bits);
/* XOR 距离落在第几桶（0=只差最后一位；159=最高位不同） */
int kad_bucket_of(const uint8_t self[ID_BYTES], const uint8_t other[ID_BYTES]);
int kad_closer(const uint8_t a[ID_BYTES], const uint8_t b[ID_BYTES],
               const uint8_t t[ID_BYTES]); /* a 比 b 更近于 t？ */

/* RPC 模拟：向 node 询问离 target 最近的 K 个（含它自己），返回个数 */
int kad_rpc_find_node(int node, const uint8_t target[ID_BYTES], int out[KAD_K]);
/* 迭代查找（α=KAD_ALPHA 并发语义）：结果 K 近写入 result，返回实际个数；
 * rpcs 统计 RPC 次数。 */
int kad_iter_find_node(int from, const uint8_t target[ID_BYTES], int result[KAD_K],
                       int *rpcs);
/* STORE：迭代找 key 的 K 近并各写一份副本；返回成功副本数 */
int kad_store(int from, const uint8_t key[ID_BYTES], const char *val);
/* FIND_VALUE：迭代查找，途中任一节点持有即短路返回（论文语义）；0=未找到 */
int kad_find_value(int from, const uint8_t key[ID_BYTES], char *val_out, size_t vsz,
                   int *rpcs);
/* 工具：十六进制打印 */
void kad_hex(const uint8_t id[ID_BYTES], char out[41]);

#endif
