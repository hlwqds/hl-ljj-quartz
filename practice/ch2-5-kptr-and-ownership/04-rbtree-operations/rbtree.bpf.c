// 04-rbtree-operations: bpf_rbtree_add 红黑树操作
//
// 对应文档 Section 5.2 - 红黑树
//
// 演示:
// - bpf_obj_new 分配树节点
// - bpf_rbtree_add 添加到红黑树 (按 key 排序)
// - 需要实现 less-than 回调函数
// - btf_decl_tag 注解让内核知道 bpf_rb_root 的元素类型
//
// 内核验证路径 (与 bpf_list_head 相同):
//   btf_parse_struct_metas() -> btf_find_graph_root()
//     -> btf_find_decl_tag_value(btf, pt, comp_idx, "contains:")

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

typedef __u32 u32;
typedef __u64 u64;

// kfunc 声明 (完整内核签名)
extern void *bpf_obj_new_impl(u64 local_type_id, void *meta) __weak __ksym;
extern void bpf_obj_drop_impl(void *p, void *meta) __weak __ksym;
extern int bpf_rbtree_add_impl(struct bpf_rb_root *root,
                                struct bpf_rb_node *node,
                                int (*less)(struct bpf_rb_node *, const struct bpf_rb_node *),
                                void *meta, u64 off) __weak __ksym;

#define bpf_obj_new(type) ((type *)bpf_obj_new_impl(bpf_core_type_id_local(type), NULL))
#define bpf_obj_drop(kptr) bpf_obj_drop_impl((void *)(kptr), NULL)
#define bpf_rbtree_add(root, node, less) bpf_rbtree_add_impl(root, node, less, NULL, 0)

// 红黑树节点
struct node {
    u32 key;
    u64 value;
    struct bpf_rb_node node;
};

// Map 值: 红黑树根
// btf_decl_tag("contains:node:node") 告诉内核:
//   - 这个 bpf_rb_root 存储的元素类型是 struct node
//   - struct node 中用于链接的字段名是 node (即 struct bpf_rb_node node)
// 格式: "contains:<value_type_name>:<node_field_name>"
struct map_value {
    struct bpf_spin_lock lock;
    struct bpf_rb_root root __attribute__((btf_decl_tag("contains:node:node")));
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct map_value);
} rb_map SEC(".maps");

// 红黑树比较函数: container_of + node.key
// bpf_rbtree_add 需要通过回调比较 key 来决定插入位置
static int node_less(struct bpf_rb_node *a, const struct bpf_rb_node *b)
{
    struct node *node_a = container_of(a, struct node, node);
    struct node *node_b = container_of(b, struct node, node);
    return node_a->key < node_b->key;
}

SEC("fentry/do_sys_openat2")
int add_to_tree(u64 *ctx)
{
    u32 key = 0;
    struct map_value *v = bpf_map_lookup_elem(&rb_map, &key);
    if (!v)
        return 0;

    // 1. 分配新节点
    struct node *n = bpf_obj_new(typeof(*n));
    if (!n)
        return 0;

    n->key = bpf_get_prandom_u32();
    n->value = bpf_ktime_get_ns();

    // 2. 添加到红黑树 (自动按 key 排序)
    // Verifier 要求调用 bpf_rbtree_add 前必须已持有同一个 map value 中的 bpf_spin_lock
    bpf_spin_lock(&v->lock);
    bpf_rbtree_add(&v->root, &n->node, node_less);
    bpf_spin_unlock(&v->lock);

    // 3. 此时 n 的所有权已转移给红黑树，不能再直接使用 n!
    //    n->key = 0;  // ❌ Verifier 拒绝: use after transfer
    //
    // 注意: bpf_rbtree_add 返回值无需处理，原因:
    //   - 成功 (返回 0): 节点归树所有，所有权已转移
    //   - 失败 (返回 -EINVAL): 节点已被 add 过 (owner != NULL)，
    //     内核在 __bpf_rbtree_add (helpers.c:2445) 中已自动调用 __bpf_obj_drop_impl 释放
    //     BPF 程序不需要也不能再释放 (unlock 后 non_owning_ref 已被 invalidate)

    return 0;
}

char _license[] SEC("license") = "GPL";
