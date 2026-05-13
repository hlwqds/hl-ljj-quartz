// 07-alu32-ptr-truncation: 正确写法 — 64-bit 全程保留指针类型
//
// 对应文档 Section 3.2.1
//
// 关键: 始终用 64-bit (void *) 或 (u64) 操作指针。
// Verifier 会追踪 PTR_TO_PACKET 类型，自动验证边界。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u16 u16;

SEC("xdp")
int truncation_good(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // ✅ 直接赋值 — data 是 PTR_TO_PACKET
    struct ethhdr *eth = data;

    // ✅ Verifier 知道 eth 是 PTR_TO_PACKET
    // 边界检查通过后，eth->h_proto 的偏移 (12) 在合法范围内
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    // ✅ Verifier 确认: eth + 12 (offsetof h_proto) + 2 (sizeof u16)
    //              = 14 <= sizeof(struct ethhdr) <= data_end - data
    u16 proto = eth->h_proto;

    return proto == 0x0008 ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
