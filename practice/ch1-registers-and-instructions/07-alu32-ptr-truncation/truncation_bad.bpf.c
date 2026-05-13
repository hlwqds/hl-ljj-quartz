// 07-alu32-ptr-truncation: 32-bit 指针截断
//
// 对应文档 Section 3.2.1 警告框
//
// BPF_ALU (32-bit) 操作会自动零扩展到 64-bit。
// 如果对一个 64-bit 指针执行 32-bit 操作，高 32 位会被清零 → 指针损坏。
//
// 本程序演示: 将 packet 指针截断为 u32 再转回。
// Verifier 看到转回后的值是 SCALAR_VALUE (不是 PTR_TO_PACKET)，
// 拒绝解引用操作。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;

SEC("xdp")
int truncation_bad(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // ❌ 将 64-bit 指针截断为 32-bit
    // 在 64-bit 系统上，指针高 32 位丢失！
    u32 data32 = (u32)(long)data;
    data32 += sizeof(struct ethhdr);  // 32-bit 加法，高 32 位始终为零

    // 转回指针 — 但 Verifier 追踪到这只是一个 SCALAR_VALUE
    // 因为中间经过了 u32 截断，类型信息已丢失
    void *eth_ptr = (void *)(unsigned long)data32;

    struct ethhdr *eth = (struct ethhdr *)eth_ptr;
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    // ❌ Verifier: eth 不是 PTR_TO_PACKET，是 SCALAR_VALUE
    // 无法对 scalar 执行内存解引用
    u16 proto = eth->h_proto;

    return proto == 0x0008 ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
