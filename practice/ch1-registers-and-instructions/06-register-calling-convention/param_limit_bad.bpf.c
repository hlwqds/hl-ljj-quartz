// 06-register-calling-convention: 参数数量限制
//
// 对应文档 Section 2.2 (寄存器详解) + Section 4.2 (参数限制：5 个)
//
// eBPF ISA 只有 R1-R5 五个参数寄存器。
// clang 在编译时会检查：BPF 子函数最多 5 个参数。
//
// 注意: __always_inline / static 函数会被 clang 内联，绕过参数数量检查。
// 必须用全局函数 (非 static) 才能触发编译错误。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

// ❌ 6 个参数 — 超过 eBPF 的 5 参数限制
// clang 编译错误: "stack arguments are not supported"
// 原因: BPF 只有 R1-R5 五个参数寄存器，无法传递第 6 个参数
// 必须是全局函数 (非 static)，否则 clang 会内联绕过检查
u64 compute_sum(u64 a, u64 b, u64 c, u64 d, u64 e, u64 f)
{
    return a + b + c + d + e + f;
}

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u64);
} result_map SEC(".maps");

SEC("xdp")
int param_limit_bad(struct xdp_md *ctx)
{
    u32 key = 0;
    u64 val = compute_sum(1, 2, 3, 4, 5, 6);
    bpf_map_update_elem(&result_map, &key, &val, BPF_ANY);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
