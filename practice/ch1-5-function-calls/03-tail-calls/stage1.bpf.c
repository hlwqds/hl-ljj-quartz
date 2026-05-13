// 03-tail-calls/stage1: 包处理管线 — 阶段 1 (L3 解析)

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

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

static void record_stage(u32 stage)
{
    u64 *count = bpf_map_lookup_elem(&stage_stats, &stage);
    if (count)
        __sync_fetch_and_add(count, 1);
}

SEC("xdp/stage1")
int stage1_l3(struct xdp_md *ctx)
{
    record_stage(1);

    // Tail Call 跳转到阶段 2 (L4 策略)
    bpf_tail_call(ctx, &jump_table, 2);

    // 跳转失败时的默认逻辑
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
