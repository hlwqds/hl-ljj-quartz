// 01-bytecode-inspect: 演示 eBPF 字节码基本结构
//
// 本程序包含文档 Section 3 中提到的各类指令：
// - ALU 运算（加法、移位）
// - 内存访问（从 Context 加载指针、读取结构体字段）
// - 条件跳转（边界检查）
// - Helper 函数调用（Map 查找）
// - 程序返回
//
// 编译后用 llvm-objdump 查看生成的字节码

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;

// 简单 Hash Map：统计处理过的数据包数量
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u64);
} pkt_count SEC(".maps");

SEC("xdp")
int xdp_bytecode_demo(struct xdp_md *ctx)
{
    // === 内存访问指令 (BPF_LDX) ===
    // 从 ctx 结构体加载 data 和 data_end 指针
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 加载 Ethernet 头部
    struct ethhdr *eth = data;

    // === 条件跳转指令 (BPF_JMP) ===
    // 边界检查：确保 Ethernet 头在包数据范围内
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    // === ALU 运算指令 (BPF_ALU64) ===
    // 计算包大小（字节）
    u64 pkt_size = (u64)(data_end - data);
    // 算术右移：除以 512，粗略估算"512 字节块"数
    u64 chunks = pkt_size >> 9;

    // === Helper 函数调用 (BPF_CALL) ===
    // 调用 bpf_map_lookup_elem，通过 R1-R5 传参
    u32 key = 0;
    u64 *count = bpf_map_lookup_elem(&pkt_count, &key);
    if (count) {
        // 原子加法（编译为 BPF_ATOMIC 指令）
        __sync_fetch_and_add(count, 1);
    }

    // === 返回指令 (BPF_EXIT) ===
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
