// 03-bounded-loops/invalid_loop: 非法的无界循环
//
// 对应文档 Section 4.4 - 无界循环 (Unbounded Loops)
//
// 以下代码能被 clang 编译为 BPF 字节码，
// 但 Verifier 在加载时会拒绝——因为它无法确定循环上界。
//
// 编译会成功！但加载到内核时会失败。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u32 u32;

// 非法示例 1: 运行时变量作为循环上界
// n 来自包数据，Verifier 无法推断最大值
SEC("xdp")
int invalid_runtime_bound(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    // 从包中读取一个字节作为循环上界
    u8 *proto = (u8 *)(data + 14);  // IP protocol field
    if ((void *)(proto + 1) > data_end)
        return XDP_DROP;

    u8 n = *proto;  // 运行时值！Verifier 不知道 n 的范围

    // 非法: Verifier 无法确定 n 的上界
    // 可能是 0，也可能是 255
    u32 sum = 0;
    for (int i = 0; i < n; i++) {
        sum += i;
    }

    return sum & 0xFF;
}

// 非法示例 2: while 循环，条件依赖运行时数据
SEC("xdp")
int invalid_while_loop(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    u8 *ptr = (u8 *)data;
    u32 count = 0;

    // 非法: while 循环，退出条件依赖运行时数据
    // Verifier 无法证明循环一定会终止
    while ((void *)(ptr + 1) <= data_end) {
        if (*ptr == 0xFF)
            break;
        ptr++;
        count++;
    }

    return count;
}

char _license[] SEC("license") = "GPL";
