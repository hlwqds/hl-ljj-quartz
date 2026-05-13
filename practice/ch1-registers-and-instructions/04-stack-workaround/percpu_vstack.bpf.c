// 04-stack-workaround: 使用 Per-CPU Map 突破 512 字节栈限制
//
// 对应文档 Section 4.1 - 栈空间限制：512 字节
//
// 方案: 使用 BPF_MAP_TYPE_PERCPU_ARRAY 作为"虚拟栈"
// - 每个 CPU 独享一份内存，无锁竞争
// - 大小不受 512 字节限制
// - 适合处理需要大缓冲区的场景
//
// 需要较新内核 (5.10+) 支持 BPF_MAP_TYPE_PERCPU_ARRAY

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u32 u32;
typedef __u64 u64;

// 超过 512 字节栈限制的大型缓冲区
#define LARGE_BUF_SIZE 4096

struct large_buffer {
    char data[LARGE_BUF_SIZE];
    u32  bytes_processed;
    u64  timestamp;
};

// Per-CPU Array Map: 每个 CPU 独享一份 large_buffer
// 相当于一个"虚拟栈"，不受 512 字节限制
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, struct large_buffer);
} vstack SEC(".maps");

SEC("xdp")
int process_large_packet(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 确保包至少有 64 字节可读 (覆盖下面的循环拷贝)
    if (data + 64 > data_end)
        return XDP_DROP;

    // === 方案: 通过 Per-CPU Map 获取大缓冲区 ===
    u32 key = 0;
    struct large_buffer *buf = bpf_map_lookup_elem(&vstack, &key);
    if (!buf)
        return XDP_DROP;

    // 现在可以使用 buf->data (4096 字节) 了!
    // 远超 512 字节的栈限制
    u32 pkt_len = (u32)(data_end - data);
    u32 copy_len = pkt_len < LARGE_BUF_SIZE ? pkt_len : LARGE_BUF_SIZE;

    // 将包数据拷贝到我们的"虚拟栈"
    // 注意: 需要 helper 函数 (bpf_probe_read_kernel / bpf_memcpy)
    // 这里用简单的循环演示
    for (int i = 0; i < copy_len && i < 64; i++) {
        buf->data[i] = ((u8 *)data)[i];
    }
    buf->bytes_processed = copy_len;
    buf->timestamp = bpf_ktime_get_ns();

    // 后续可以对 buf->data 做任意处理...
    // 例如: 协议解析、正则匹配、数据变换等

    return XDP_PASS;
}

// 额外示例: 使用局部 kptr 在堆上分配 (Linux 5.12+, 需要特定 BTF 支持)
// 这是文档中提到的方案 2
//
// 注意: 局部 kptr 需要在 BTF 中标记为 __kptr 标志，
// 且需要内核支持 bpf_obj_new/bpf_obj_drop
// 以下代码仅供参考，可能需要较新内核和 libbpf 版本

/*
struct my_heap_obj {
    int data[256];
    u32 count;
};

// 需要在 BTF 中声明为可分配类型
struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 24);  // 16MB ring buffer
} heap SEC(".maps");

SEC("kprobe")
int kptr_example(struct pt_regs *ctx)
{
    // 在堆上分配，不受栈限制
    struct my_heap_obj *obj = bpf_obj_new(typeof(*obj));
    if (!obj)
        return 0;

    obj->count = 0;
    // ... 使用 obj ...

    // 必须释放！否则内存泄漏
    bpf_obj_drop(obj);
    return 0;
}
*/

char _license[] SEC("license") = "GPL";
