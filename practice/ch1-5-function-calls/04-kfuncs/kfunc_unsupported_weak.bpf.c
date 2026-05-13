// 04-kfuncs: 不存在的 kfunc — __weak 弱引用对照
//
// 演示 __weak __ksym 的优雅降级:
// - 声明不存在的 kfunc bpf_do_something_magical_weak
// - bpf_ksym_exists 在运行时检测到不存在 → 跳过调用
// - 程序正常加载和运行

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

extern void bpf_do_something_magical_weak(u32 x) __weak __ksym;

SEC("fentry/do_unlinkat")
int kfunc_unsupported_weak(u64 *ctx)
{
    if (!bpf_ksym_exists(bpf_do_something_magical_weak)) {
        // 内核不支持 → 优雅降级
        return 0;
    }

    // 实际运行不会到这里
    bpf_do_something_magical_weak(42);
    return 0;
}

char _license[] SEC("license") = "GPL";
