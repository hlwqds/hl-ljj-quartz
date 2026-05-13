// 03-tail-calls/stage0: 包处理管线 — 阶段 0 (L2 解析)
//
// 对应文档 Section 4 - Tail Calls：跨程序跳转
//
// 三个独立的 SEC("xdp/stage*") 程序，
// 通过 BPF_MAP_TYPE_PROG_ARRAY + bpf_tail_call 串联。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 3);
    __uint(key_size, sizeof(u32));
    __uint(value_size, sizeof(u32));
} jump_table SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 3);
    __type(key, u32);
    __type(value, u64);
} stage_stats SEC(".maps");

// 记录统计
static void record_stage(u32 stage)
{
    u64 *count = bpf_map_lookup_elem(&stage_stats, &stage);
    if (count)
        __sync_fetch_and_add(count, 1);
}

SEC("xdp/stage0")
int stage0_l2(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 边界检查
    if (data + sizeof(struct ethhdr) > data_end)
        return XDP_DROP;

    struct ethhdr *eth = data;
    u16 eth_type = eth->h_proto;

    record_stage(0);

    // 非 IPv4，直接放行 (不跳转后续阶段)
    if (eth_type != 0x0008)
        return XDP_PASS;

    // Tail Call 跳转到阶段 1 (L3 解析)
    bpf_tail_call(ctx, &jump_table, 1);

    // 如果跳转失败 (阶段 1 不存在)，走默认逻辑
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
