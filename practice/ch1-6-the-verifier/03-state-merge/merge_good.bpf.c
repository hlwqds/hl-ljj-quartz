// 03-state-merge: 避免状态合并退化
//
// 对应文档 Section 2.2
//
// 两种方案:
//   方案 1: 两分支赋相同类型，合并后不退化
//   方案 2: 合并后重新判空/检查

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct value_t {
    u64 counter;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct value_t);
} my_map SEC(".maps");

// 方案 1: 两分支赋相同类型
SEC("fentry/do_sys_openat2")
int merge_good_same_type(u64 *ctx)
{
    u32 key = 0;
    struct value_t *v;

    u32 flag = bpf_get_prandom_u32();

    if (flag & 1) {
        // 路径 A: v = PTR_TO_MAP_VALUE_OR_NULL
        v = bpf_map_lookup_elem(&my_map, &key);
    } else {
        // 路径 B: v = PTR_TO_MAP_VALUE_OR_NULL (同类型)
        v = bpf_map_lookup_elem(&my_map, &key);
    }

    // 合并: PTR_TO_MAP_VALUE_OR_NULL + PTR_TO_MAP_VALUE_OR_NULL → PTR_TO_MAP_VALUE_OR_NULL
    // 类型不退化！

    // ✅ 合并后判空
    if (!v)
        return 0;

    v->counter = 42;
    return 0;
}

char _license[] SEC("license") = "GPL";
