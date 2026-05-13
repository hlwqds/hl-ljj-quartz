// 01-null-deref: NULL 解引用 (Verifier 最常见错误)
//
// 对应文档 Section 6.1
//
// bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE_OR_NULL，
// 必须先判空才能解引用。
// 这里故意不判空，Verifier 会拒绝加载。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u64);
} counter_map SEC(".maps");

SEC("xdp")
int null_deref_bad(struct xdp_md *ctx)
{
    u32 key = 0;

    // bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE_OR_NULL
    // Verifier: R0 = ptr_or_null_map_value
    u64 *value = bpf_map_lookup_elem(&counter_map, &key);

    // ❌ 没有判空直接解引用！
    // Verifier: R0 可能是 NULL，不能解引用
    *value += 1;

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
