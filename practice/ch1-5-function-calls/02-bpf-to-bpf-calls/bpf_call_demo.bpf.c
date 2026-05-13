// 02-bpf-to-bpf-calls: BPF-to-BPF Call 子函数调用
//
// 对应文档 Section 3 - BPF-to-BPF Calls
//
// 演示:
// - __always_inline 子函数 (编译器展开)
// - static 非 inline 子函数 (生成 BPF_CALL 指令)
// - 寄存器状态: R6-R9 callee-saved, R1-R5 caller-saved

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} counter_map SEC(".maps");

// __always_inline: 编译器直接展开到调用处
// 对应文档 Section 3.2 的 "inline" 列
static __always_inline int parse_header(struct xdp_md *ctx, u32 *out_proto)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    if (data + 14 > data_end)
        return -1;

    // 读取以太网协议类型
    u16 eth_type;
    __builtin_memcpy(&eth_type, (u8 *)data + 12, 2);
    *out_proto = eth_type;
    return 0;
}

// static (非 inline): 生成独立的 BPF_CALL 指令
// 对应文档 Section 3.2 的 "static" 列
static int do_map_lookup(u32 key)
{
    u64 *count = bpf_map_lookup_elem(&counter_map, &key);
    if (count) {
        __sync_fetch_and_add(count, 1);
        return (int)*count;
    }
    return 0;
}

SEC("xdp")
int bpf_call_demo(struct xdp_md *ctx)
{
    u32 proto;

    // __always_inline 调用: 代码直接展开，无 BPF_CALL 指令
    if (parse_header(ctx, &proto) < 0)
        return XDP_DROP;

    // static 调用: 生成 BPF_CALL 指令
    int count = do_map_lookup(proto);

    return count ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
