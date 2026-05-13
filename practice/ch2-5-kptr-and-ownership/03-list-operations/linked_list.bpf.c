// 03-list-operations: bpf_list_push_back 链表操作
//
// 对应文档 Section 5.1 - 链表
//
// 演示:
// - bpf_obj_new 分配链表节点
// - bpf_list_push_back 将节点添加到链表尾部
// - 所有权自动转移: push 后不能再直接使用该节点
// - btf_decl_tag 注解让内核知道 bpf_list_head 的元素类型
//
// 内核验证路径 (kernel/bpf/btf.c):
//   BPF_BTF_LOAD
//     -> btf_parse_struct_metas()          // 扫描所有 struct，找含特殊字段的
//        -> btf_parse_fields()              // 解析 map_value 中的特殊字段
//           -> btf_find_field()             // 发现 bpf_list_head
//              -> btf_find_graph_root()     // 读取 decl_tag: "contains:node:node"
//                 -> btf_find_decl_tag_value(btf, pt, comp_idx, "contains:")
//           -> btf_parse_list_head()        // 验证 value type 中的 bpf_list_node
//              -> btf_parse_graph_root()    // 遍历 value struct 找 node 字段
//        -> btf_check_and_fixup_fields()    // 检查 spin_lock 配对、所有权环

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

typedef __u32 u32;
typedef __u64 u64;

// kfunc 声明 (完整内核签名，含 __weak 标记)
// 来自 vmlinux.h: bpftool btf dump file /sys/kernel/btf/vmlinux format c
extern void *bpf_obj_new_impl(u64 local_type_id, void *meta) __weak __ksym;
extern void bpf_obj_drop_impl(void *p, void *meta) __weak __ksym;
extern int bpf_list_push_back_impl(struct bpf_list_head *head,
                                    struct bpf_list_node *node,
                                    void *meta, u64 off) __weak __ksym;

// 便捷宏: 封装 _impl 调用
// bpf_core_type_id_local 在编译时解析为 BTF type ID
#define bpf_obj_new(type) ((type *)bpf_obj_new_impl(bpf_core_type_id_local(type), NULL))
#define bpf_obj_drop(kptr) bpf_obj_drop_impl((void *)(kptr), NULL)
// bpf_list_push_back_impl 需要 4 个参数 (head, node, meta__ign, off)
#define bpf_list_push_back(head, node) bpf_list_push_back_impl(head, node, NULL, 0)

// 链表节点: 包含数据 + bpf_list_node (内核链表锚点)
// bpf_list_node 是不透明类型，只能通过 kfunc 操作
struct node {
    u32 value;
    struct bpf_list_node node;  // 内核链表节点
};

// Map 值: 链表头
// bpf_spin_lock + bpf_list_head 是标准配对:
//   - lock 保护链表的并发访问
//   - head 是链表入口 (内含 __kptr)
//
// btf_decl_tag("contains:node:node") 告诉内核 BTF 验证器:
//   - 这个 bpf_list_head 存储的元素类型是 struct node
//   - struct node 中用于链接的字段名是 node (即 struct bpf_list_node node)
//
// 格式: "contains:<value_type_name>:<node_field_name>"
// 引入: kernel 6.2 (commit f0c5941ff5b2, Kumar Kartikeya Dwivedi, 2022-11)
struct map_value {
    struct bpf_spin_lock lock;
    struct bpf_list_head head __attribute__((btf_decl_tag("contains:node:node")));
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct map_value);
} list_map SEC(".maps");

SEC("fentry/do_sys_openat2")
int add_to_list(u64 *ctx)
{
    u32 key = 0;
    struct map_value *v = bpf_map_lookup_elem(&list_map, &key);
    if (!v)
        return 0;

    // 1. 分配新节点
    // bpf_obj_new 通过 BTF type ID 在 BPF 堆上分配
    struct node *n = bpf_obj_new(typeof(*n));
    if (!n)
        return 0;

    n->value = bpf_get_prandom_u32();

    // 2. 添加到链表尾部
    // Verifier 要求调用 bpf_list_push_back 前必须已持有同一个 map value 中的 bpf_spin_lock
    // 这是编译期检查，kfunc 不会内部加锁
    bpf_spin_lock(&v->lock);
    bpf_list_push_back(&v->head, &n->node);
    bpf_spin_unlock(&v->lock);

    // 3. 此时 n 的所有权已转移给链表，不能再直接使用 n!
    //    n->value = 0;  // ❌ Verifier 拒绝: use after transfer

    return 0;
}

char _license[] SEC("license") = "GPL";
