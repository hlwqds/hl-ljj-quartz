// 05-jit-debug: 用于对比 JIT vs 解释执行的 BPF 程序
//
// 对应文档 Section 6 - JIT 编译原理
//
// 本程序包含多种指令类型，便于对比:
//   - xlated (eBPF 字节码): Verifier 输出的通用指令
//   - jited  (x86_64 原生):  JIT 编译后的机器码
//
// 关注点:
//   - 64-bit 加法: eBPF 1 条 → x86_64 1-2 条 (ADD)
//   - 条件跳转:   eBPF 1 条 → x86_64 1-2 条 (CMP+Jcc)
//   - Map 查找:   eBPF 1 条 call → x86_64 多条 (函数调用)
//   - 32-bit 操作: eBPF 1 条 → x86_64 1 条 (零扩展到 64-bit)

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} counter SEC(".maps");

SEC("xdp")
int jit_demo(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    if (data + sizeof(struct ethhdr) > data_end)
        return XDP_DROP;

    // ALU: 64-bit 算术运算
    u64 pkt_size = (u64)(data_end - data);
    u64 hash = pkt_size * 31;

    // ALU: 32-bit 操作 (自动零扩展)
    u32 key = (u32)(hash & 0xFFFF);
    hash >>= 16;

    // Helper 调用 (Map 查找)
    u64 *count = bpf_map_lookup_elem(&counter, &key);
    if (count)
        __sync_fetch_and_add(count, 1);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
