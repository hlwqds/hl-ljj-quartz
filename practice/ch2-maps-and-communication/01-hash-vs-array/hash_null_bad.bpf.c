// 01-hash-vs-array: HASH Map NULL 解引用
//
// 对应文档 Section 3 (Hash Map 深度剖析)
//
// HASH map 的 bpf_map_lookup_elem 返回 PTR_TO_MAP_VALUE_OR_NULL:
//   - key 存在 → 返回指向 value 的指针
//   - key 不存在 → 返回 NULL
//
// Verifier 要求必须先检查 NULL 再解引用。

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

SEC("fentry/do_sys_openat2")
int hash_null_bad(u64 *ctx)
{
    u32 key = 0;

    // ❌ HASH lookup 可能返回 NULL，但直接解引用
    // Verifier 看到: R0 = PTR_TO_MAP_VALUE_OR_NULL
    // 然后: *R0 → invalid mem access 'map_value_or_null'
    u64 *count = bpf_map_lookup_elem(&counter_map, &key);
    *count += 1;

    return 0;
}

char _license[] SEC("license") = "GPL";
