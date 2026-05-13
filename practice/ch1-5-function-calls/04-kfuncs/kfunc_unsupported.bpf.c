// 04-kfuncs: 不存在的 kfunc 实验对照
//
// 演示两种 kfunc 不存在时的行为差异:
//
// Case 1 (non-weak): kfunc_unsupported_strong
//   - 声明不存在的 kfunc，不加 __weak
//   - 预期: verifier 报错 "kernel module BTF is not found" 或 "invalid func"
//   - 程序完全无法加载
//
// Case 2 (weak): kfunc_unsupported_weak
//   - 声明不存在的 kfunc，加 __weak __ksym
//   - 预期: 加载成功，bpf_ksym_exists 返回 false，kfunc 调用被跳过
//   - 程序正常运行，只是该 kfunc 不可用

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

// ============================================================
// Case 1: 不存在的 kfunc，非 __weak (强引用)
// ============================================================

// 随便编一个名字: bpf_do_something_magical
// 这个 kfunc 在任何内核都不存在
extern void bpf_do_something_magical(u32 x) __ksym;

SEC("fentry/do_sys_openat2")
int kfunc_unsupported_strong(u64 *ctx)
{
    // 直接调用不存在的 kfunc
    // verifier 会尝试在内核 BTF 中查找这个符号
    // 找不到 → 拒绝加载
    bpf_do_something_magical(42);
    return 0;
}

// ============================================================
// Case 2: 不存在的 kfunc，__weak (弱引用)
// ============================================================

extern void bpf_do_something_magical_weak(u32 x) __weak __ksym;

SEC("fentry/do_unlinkat")
int kfunc_unsupported_weak(u64 *ctx)
{
    // bpf_ksym_exists: 编译时生成检查，运行时判断 kfunc 是否存在
    if (!bpf_ksym_exists(bpf_do_something_magical_weak)) {
        // 内核不支持这个 kfunc，优雅降级
        // 这里可以放 fallback 逻辑
        return 0;
    }

    // 如果 kfunc 存在才调用 (实际运行不会到这里)
    bpf_do_something_magical_weak(42);
    return 0;
}

char _license[] SEC("license") = "GPL";
