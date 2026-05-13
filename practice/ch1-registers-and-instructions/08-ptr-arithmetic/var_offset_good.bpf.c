// 08-ptr-arithmetic: 正确写法 — 编译时常量偏移
//
// 对应文档 Section 4.5
//
// 编译时已知的常量偏移，Verifier 可以在验证阶段确认:
//   offset + sizeof(access) <= data_end - data
//
// 关键: sizeof()、offsetof() 都是编译时常量。

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u16 u16;

SEC("xdp")
int var_offset_good(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 边界检查: 确保 Ethernet 头完整
    if (data + sizeof(struct ethhdr) > data_end)
        return XDP_DROP;

    // ✅ 编译时常量偏移 (12 = offsetof(struct ethhdr, h_proto))
    // Verifier 计算: 12 + sizeof(u16) = 14 <= sizeof(struct ethhdr) = 14 <= data_end - data ✓
    u8 *target = (u8 *)data + 12;
    u16 val = *(u16 *)target;

    return val == 0x0008 ? XDP_PASS : XDP_DROP;
}

char _license[] SEC("license") = "GPL";
