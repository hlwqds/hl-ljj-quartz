// 02-percpu-map: Per-CPU Map 计数器
//
// 对应文档 Section 4.2 (Per-CPU Map：无锁并发的秘密)
//
// Per-CPU Map 为每个 CPU 核心分配独立的 value 副本。
// BPF 程序直接写入当前 CPU 的副本，无需锁。
//
// 本程序: XDP 按以太网协议类型统计包数。
// 加载后用 bpftool map dump 观察每个 CPU 的独立计数。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;

// Per-CPU Array: 每个 CPU 独立一份 u64 计数器
// 索引 0 = 其他协议, 索引 1 = IPv4 (0x0800), 索引 2 = IPv6 (0x86DD), 索引 3 = ARP
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 4);
    __type(key, u32);
    __type(value, u64);
} proto_counter SEC(".maps");

// 对比: 普通 ARRAY 计数器 (需要原子操作)
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, u32);
    __type(value, u64);
} proto_counter_locked SEC(".maps");

static __always_inline u32 proto_to_index(u16 proto)
{
    if (proto == 0x0008) return 1;  // IPv4 (little-endian)
    if (proto == 0xDD86) return 2;  // IPv6 (little-endian)
    if (proto == 0x0608) return 3;  // ARP  (little-endian)
    return 0;
}

SEC("xdp")
int percpu_count(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    u32 idx = proto_to_index(eth->h_proto);

    // Per-CPU: 直接 += 1，无需锁！
    // 每个 CPU 写自己的副本，没有 cache line bouncing
    u64 *count = bpf_map_lookup_elem(&proto_counter, &idx);
    if (count)
        *count += 1;

    // 对比: 普通 ARRAY 需要 __sync_fetch_and_add (原子操作，跨 CPU 有开销)
    u64 *count_locked = bpf_map_lookup_elem(&proto_counter_locked, &idx);
    if (count_locked)
        __sync_fetch_and_add(count_locked, 1);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
