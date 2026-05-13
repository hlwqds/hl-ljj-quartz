// 01-null-deref: 正确的 NULL 检查
//
// 对应文档 Section 6.1 + Section 8.1 (尽早判空)
//
// bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE_OR_NULL，
// 判空后 Verifier 将类型升级为 PTR_TO_MAP_VALUE，允许解引用。

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
int null_deref_good(struct xdp_md *ctx)
{
    u32 key = 0;
    u64 *value = bpf_map_lookup_elem(&counter_map, &key);

    // ✅ 先判空
    // Verifier 在 true 分支: R0 从 ptr_or_null 升级为 ptr_map_value
    if (!value)
        return XDP_PASS;

    // Verifier: value 是 PTR_TO_MAP_VALUE，可以安全解引用
    *value += 1;

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
