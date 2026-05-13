// 05-helper-type-mismatch: Helper 参数类型不匹配
//
// 对应文档 Section 6.4
//
// bpf_map_lookup_elem 的第二个参数必须是 pointer to key。
// 如果传 scalar value 而不是 pointer，Verifier 会拒绝。
//
// 注意: clang 编译时可能不报错 (BPF helper 是通过特殊机制声明的)，
// 但 Verifier 在加载时会检查参数类型。

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
int type_bad(u64 *ctx)
{
    u32 key = 0;

    // ❌ 传 key (scalar) 而不是 &key (pointer)
    // 用 (void *) 绕过 clang 的类型检查，让 Verifier 来抓
    // Verifier 看到的是: R2 = w1 (scalar)，不是 pointer
    u64 *value = bpf_map_lookup_elem(&counter_map, (void *)(long)key);

    if (!value)
        return 0;

    *value += 1;
    return 0;
}

char _license[] SEC("license") = "GPL";
