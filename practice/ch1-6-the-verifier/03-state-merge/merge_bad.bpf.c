// 03-state-merge: 寄存器状态合并退化
//
// 对应文档 Section 2.2 (状态合并 / State Merging)
//
// 当 if/else 两分支给同一变量赋不同类型的指针时，
// 汇合点 Verifier 将类型"退化"为 SCALAR_VALUE (最保守)。
// 退化后的指针不能解引用。
//
// 核心原理:
//   路径 A: p = map_value    (PTR_TO_MAP_VALUE_OR_NULL)
//   路径 B: p = 0            (SCALAR_VALUE)
//   合并:   p = SCALAR_VALUE  (退化为标量！)
//   结果:   *p → Verifier 拒绝

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

SEC("fentry/do_sys_openat2")
int merge_bad(u64 *ctx)
{
    u32 key = 0;
    void *p;
    struct value_t *v;

    // 用 prandom 模拟运行时条件分支
    u32 flag = bpf_get_prandom_u32();

    if (flag & 1) {
        // 路径 A: p = PTR_TO_MAP_VALUE_OR_NULL
        v = bpf_map_lookup_elem(&my_map, &key);
        p = v;
    } else {
        // 路径 B: p = SCALAR_VALUE (整数 0)
        p = (void *)0;
    }

    // 汇合点: Verifier 合并两种状态
    // PTR_TO_MAP_VALUE_OR_NULL + SCALAR_VALUE → SCALAR_VALUE
    // p 现在是标量，不再是有效指针！

    // ❌ 尝试解引用 p → Verifier 拒绝
    // "invalid mem access 'scalar'"
    struct value_t *vp = p;
    vp->counter = 42;

    return 0;
}

char _license[] SEC("license") = "GPL";
