// 01-obj-new-drop: 对照组 — 内存泄漏 (Verifier 拒绝)
//
// 对应文档 Section 7.1 - 所有权追踪算法
//
// 这个程序故意不释放 bpf_obj_new 分配的对象。
// Verifier 会在加载时拒绝并报错: "Unreleased reference"
//
// 编译会成功！Verifier 在加载时才检查所有权。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

typedef __u32 u32;
typedef __u64 u64;

// kfunc 声明
extern void *bpf_obj_new_impl(u64 local_type_id, void *meta) __weak __ksym;
extern void bpf_obj_drop_impl(void *p, void *meta) __weak __ksym;

#define bpf_obj_new(type) ((type *)bpf_obj_new_impl(bpf_core_type_id_local(type), NULL))
#define bpf_obj_drop(kptr) bpf_obj_drop_impl((void *)(kptr), NULL)

struct my_data {
    u32 pid;
    u64 timestamp;
};

SEC("fentry/do_sys_openat2")
int leak_fail(u64 *ctx)
{
    // 分配内存
    struct my_data *d = bpf_obj_new(typeof(*d));
    if (!d)
        return 0;

    d->pid = bpf_get_current_pid_tgid() >> 32;
    d->timestamp = bpf_ktime_get_ns();

    // ❌ 故意不调用 bpf_obj_drop(d)
    // ❌ 也不转移所有权 (不存入 Map/链表/树)
    // Verifier 报错: "Unreleased reference"

    return 0;
}

char _license[] SEC("license") = "GPL";
