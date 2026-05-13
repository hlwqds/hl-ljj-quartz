// 01-hash-vs-array: ARRAY Map 无需判空
//
// 对应文档 Section 4.1 (Array Map)
//
// ARRAY map 对有效 key 索引 (0 <= key < max_entries) 返回 PTR_TO_MAP_VALUE:
//   - 永远返回非 NULL (内存预分配)
//   - Verifier 知道返回值一定有效 → 无需判空
//
// 这是 ARRAY map 和 HASH map 的关键区别。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u64);
} counter_map SEC(".maps");

SEC("fentry/do_sys_openat2")
int array_no_null_good(u64 *ctx)
{
    u32 key = 0;

    // ✅ ARRAY lookup 对有效 key 永远返回非 NULL
    // Verifier 看到: R0 = PTR_TO_MAP_VALUE (不是 OR_NULL)
    // 直接解引用: 合法
    u64 *count = bpf_map_lookup_elem(&counter_map, &key);
    *count += 1;

    return 0;
}

char _license[] SEC("license") = "GPL";
