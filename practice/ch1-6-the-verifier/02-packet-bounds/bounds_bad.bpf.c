// 02-packet-bounds: 包越界访问 (XDP 最常见 Verifier 错误)
//
// 对应文档 Section 6.3 + Section 4.1 (三层边界检查)
//
// XDP 程序访问包数据前必须检查 data_end。
// 这里直接访问 eth->h_proto 不检查边界，Verifier 会拒绝。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u16 u16;

SEC("xdp")
int bounds_bad(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;

    // ❌ 没有检查 (void *)(eth + 1) > data_end
    // Verifier 不知道 eth + sizeof(ethhdr) 是否在包范围内
    // 可能收到一个只有 10 字节的包 (不够 14 字节的 ethhdr)
    u16 proto = eth->h_proto;

    return proto == 0x0800 ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
