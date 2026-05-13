// 02-bpf-to-bpf-calls: 对照组 — 栈共享陷阱 (kprobe, adaptive private stack)
//
// 对应文档 Section 3.3 - 栈共享陷阱
//
// 主函数和子函数各自使用大栈变量，
// 但 kprobe 程序类型启用 PRIV_STACK_ADAPTIVE，
// 每个 subprog 获得独立栈帧，不共享 512B 限制。
// 因此 300 + 250 = 550B 在 kprobe 下可以正常加载。
//
// 对比: stack_overflow_nopriv.bpf.c 使用 cgroup_skb 类型 (NO_PRIV_STACK)，
// 同样的代码会触发 "combined stack size ... Too large"
//
// 注意:
// - __noinline__ 防止 clang 内联 (否则栈帧合并，不会超限)
// - use_buf 强制使用栈空间 (防止编译器优化掉)

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
static void use_buf(void *dst, int len)
{
    volatile u8 *p = (volatile u8 *)dst;
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

SEC("kprobe/do_sys_openat2")
int stack_overflow(struct pt_regs *ctx)
{
    struct big_main buf;
    use_buf(buf.data, sizeof(buf));

    // 调用子函数: 合计 300 + 250 = 550 > 512
    return sub_func();
}

char _license[] SEC("license") = "GPL";
