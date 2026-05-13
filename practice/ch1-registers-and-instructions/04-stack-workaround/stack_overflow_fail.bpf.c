// 04-stack-workaround/stack_overflow_fail: 对照组 — 栈上分配超过 512 字节
//
// 对应文档 Section 4.1 - 栈空间限制：512 字节
//
// 这个程序会在栈上分配 600 字节的数组，超过 eBPF 的 512 字节限制。
// Verifier 会拒绝加载并报错: "stack size > 512"
//
// 编译会成功（clang 不检查栈大小），但加载会被 Verifier 拒绝。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;

SEC("xdp")
int stack_overflow_fail(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    if (data + 1 > data_end)
        return XDP_DROP;

    // 分配 600 字节栈空间 (> 512 字节限制)
    // asm volatile 内存屏障防止编译器优化掉整个数组
    char big_buf[600];
    __builtin_memset(big_buf, 0, sizeof(big_buf));
    asm volatile("" : : "r"(big_buf) : "memory");
    big_buf[0] = ((u8 *)data)[0];
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
