// 04-path-explosion: 解决路径爆炸 — early return + 子函数
//
// 对应文档 Section 5.2 + Section 8.3
//
// good 版本用 early return 模式：每个 if 不满足时立即返回。
// 这将路径数从 2^N 降为 N。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, u32);
    __type(value, u64);
} stats_map SEC(".maps");

// ✅ 用子函数封装每层逻辑
// 每个子函数内部: 2 条路径 (if true / if false)
// 但子函数返回后主函数只有 1 条路径继续
static void process_level(u32 idx, u32 flags, u64 *sum)
{
    if (flags & (1 << idx)) {
        *sum += bpf_get_prandom_u32();
    }
}

SEC("fentry/do_sys_openat2")
int explosion_good(u64 *ctx)
{
    u32 flags = bpf_get_prandom_u32();
    u64 sum = 0;

    // 15 个独立子函数调用
    // 每个子函数 2 条路径 → 总路径: 15 × 2 = 30 (而非 2^15 = 32768)
    process_level(0, flags, &sum);
    process_level(1, flags, &sum);
    process_level(2, flags, &sum);
    process_level(3, flags, &sum);
    process_level(4, flags, &sum);
    process_level(5, flags, &sum);
    process_level(6, flags, &sum);
    process_level(7, flags, &sum);
    process_level(8, flags, &sum);
    process_level(9, flags, &sum);
    process_level(10, flags, &sum);
    process_level(11, flags, &sum);
    process_level(12, flags, &sum);
    process_level(13, flags, &sum);
    process_level(14, flags, &sum);

    u32 key = 0;
    u64 *v = bpf_map_lookup_elem(&stats_map, &key);
    if (v)
        *v = sum;

    return 0;
}

char _license[] SEC("license") = "GPL";
