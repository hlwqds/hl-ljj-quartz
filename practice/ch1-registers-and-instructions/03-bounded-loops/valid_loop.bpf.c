// 03-bounded-loops/valid_loop: 合法的有界循环
//
// 对应文档 Section 4.4 - 有界循环 (Bounded Loops)
//
// Verifier 能在编译时推断循环次数上限的程序是合法的。
// 本程序展示几种 Verifier 可接受的有界循环写法。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u32 u32;

// 示例 1: 常量上界循环
// Verifier 知道最多执行 64 次，可以展开验证每一步
SEC("xdp")
int valid_const_bound(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 确保包至少有一个字节可读
    if (data + 1 > data_end)
        return XDP_DROP;

    // 合法: 上界 64，Verifier 展开验证每一步
    u32 sum = 0;
    for (int i = 0; i < 64; i++) {
        // 每次访问前检查边界
        if ((void *)((u8 *)data + i) >= data_end)
            break;
        sum += ((u8 *)data)[i];
    }

    return (sum & 0xFF) ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
