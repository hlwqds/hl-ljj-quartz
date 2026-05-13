// 02-bpf-to-bpf-calls: 栈共享陷阱 (NO_PRIV_STACK 程序类型)
//
// 对应文档 Section 3.3 - 栈共享陷阱
//
// 使用 cgroup_skb 程序类型，该类型不启用 PRIV_STACK_ADAPTIVE，
// subprog 栈帧仍然累加共享 512B。
//
// 主函数 300B + 子函数 250B = 550B > 512B → verifier 拒绝
//
// 对比: 同样的代码在 kprobe 类型下可以加载 (adaptive private stack)

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u8 u8;
typedef __u32 u32;
typedef __u64 u64;

// 主函数: 300 字节栈
struct big_main {
    u8 data[300];
};

// 子函数: 250 字节栈
struct big_sub {
    u8 data[250];
};

// 防止编译器优化: 强制写入并读取所有字节
__attribute__((noinline))
static void use_buf(volatile u8 *p, int len)
{
    for (int i = 0; i < len; i++)
        p[i] = (u8)i;
}

__attribute__((noinline))
static int sub_func(void)
{
    struct big_sub buf;
    use_buf(buf.data, sizeof(buf));
    return buf.data[0];
}

// cgroup_skb: NO_PRIV_STACK 模式，subprog 栈帧累加
SEC("cgroup_skb/egress")
int stack_overflow(struct __sk_buff *ctx)
{
    struct big_main buf;
    use_buf(buf.data, sizeof(buf));

    // 合计 300 + 250 = 550 > 512 → verifier: "combined stack size ... Too large"
    return sub_func();
}

char _license[] SEC("license") = "GPL";
