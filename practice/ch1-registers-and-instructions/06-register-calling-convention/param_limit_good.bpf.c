// 06-register-calling-convention: 参数数量限制 (解决方案)
//
// 对应文档 Section 4.2
//
// 解决方案: 用 struct 包装多个参数，只占 1 个寄存器 (R1 = pointer)。
// 这是 BPF 开发中传递超过 5 个参数的标准模式。
//
// 注意: 这里用全局函数 (非 static) 与 bad case 对比，
// struct 指针只占 1 个参数 (R1)，不受 5 参数限制。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

// ✅ 将 6 个参数打包到 struct 中
// 调用时只传递 1 个指针 (R1)，不受 5 参数限制
struct compute_params {
    u64 a;
    u64 b;
    u64 c;
    u64 d;
    u64 e;
    u64 f;
};

// 全局函数: 只有 1 个参数 (struct 指针)，远低于 5 参数限制
u64 compute_sum(struct compute_params *p)
{
    return p->a + p->b + p->c + p->d + p->e + p->f;
}

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u64);
} result_map SEC(".maps");

SEC("xdp")
int param_limit_good(struct xdp_md *ctx)
{
    u32 key = 0;

    // 通过 struct 传递 6 个参数
    struct compute_params p = {
        .a = 1, .b = 2, .c = 3,
        .d = 4, .e = 5, .f = 6,
    };
    u64 val = compute_sum(&p);

    bpf_map_update_elem(&result_map, &key, &val, BPF_ANY);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
