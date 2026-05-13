// 08-ptr-arithmetic: 运行时变量作为指针偏移
//
// 对应文档 Section 4.5 (无指针算术限制)
//
// eBPF 只允许编译时已知的常量作为指针偏移。
// 如果偏移量是运行时变量，Verifier 无法在编译时验证内存访问的合法性。
//
// 本程序: 用 bpf_get_prandom_u32() 生成运行时偏移，
// 尝试用它访问包数据 → Verifier 无法验证边界 → 拒绝。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u16 u16;
typedef __u32 u32;

SEC("xdp")
int var_offset_bad(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 确保至少有一个 Ethernet 头
    if (data + sizeof(struct ethhdr) > data_end)
        return XDP_DROP;

    // ❌ 运行时变量偏移 — n = [0, UMAX]
    // Verifier 无法确定 data + n 是否在 [data, data_end] 范围内
    u32 n = bpf_get_prandom_u32();
    u8 *target = (u8 *)data + n;

    // ❌ Verifier: 无法证明 target + sizeof(u16) <= data_end
    u16 val = *(u16 *)target;

    return val == 0x0008 ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
