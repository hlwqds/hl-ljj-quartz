// 02-packet-bounds: 正确的包边界检查链
//
// 对应文档 Section 8.2 (边界检查先行)
//
// 展示完整的 L2 → L3 → L4 边界检查模式。
// 每层解析前都验证 (header + 1) <= data_end。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int bounds_good(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // ✅ L2: 检查 ethhdr 边界
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    // Verifier: eth + 14 <= data_end → eth->h_proto (offset 12, size 2) 安全
    if (eth->h_proto != 0x0800)  // IPv4
        return XDP_PASS;

    // ✅ L3: 检查 iphdr 边界
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_DROP;

    // Verifier: ip + 20 <= data_end → ip->protocol 安全
    if (ip->protocol != 6)  // TCP
        return XDP_PASS;

    // ✅ L4: 检查 tcphdr 边界
    struct tcphdr *tcp = (void *)ip + (ip->ihl * 4);
    if ((void *)(tcp + 1) > data_end)
        return XDP_DROP;

    // Verifier: tcp + 20 <= data_end → tcp->dest 安全
    return (tcp->dest == 80) ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
