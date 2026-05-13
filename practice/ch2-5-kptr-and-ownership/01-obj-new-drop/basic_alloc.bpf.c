// 01-obj-new-drop: bpf_obj_new / bpf_obj_drop 基本用法
//
// 对应文档 Section 3 - bpf_obj_new / bpf_obj_drop：堆分配 API
//
// 演示:
// - bpf_obj_new 在 BPF 对象分配器上分配内存
// - bpf_obj_drop 释放内存
// - Verifier 在编译时验证所有权: 每个 new 必须有对应 drop 或转移

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

typedef __u32 u32;
typedef __u64 u64;

// kfunc 声明 (完整内核签名，需要 __weak 标记)
extern void *bpf_obj_new_impl(u64 local_type_id, void *meta) __weak __ksym;
extern void bpf_obj_drop_impl(void *p, void *meta) __weak __ksym;

// 便捷宏: bpf_obj_new(type) → bpf_obj_new_impl(BTF_ID(type), NULL)
#define bpf_obj_new(type) ((type *)bpf_obj_new_impl(bpf_core_type_id_local(type), NULL))
#define bpf_obj_drop(kptr) bpf_obj_drop_impl((void *)(kptr), NULL)

// 自定义数据结构，通过 bpf_obj_new 在堆上分配
struct my_data {
    u32 pid;
    u64 timestamp;
    u32 counter;
};

SEC("fentry/do_sys_openat2")
int basic_alloc(u64 *ctx)
{
    // bpf_obj_new: 在 BPF 对象分配器上分配内存
    // Verifier 标记返回的指针为 "owned"
    struct my_data *d = bpf_obj_new(typeof(*d));
    if (!d)
        return 0;

    // 使用分配的内存
    d->pid = bpf_get_current_pid_tgid() >> 32;
    d->timestamp = bpf_ktime_get_ns();
    d->counter = 1;

    // bpf_obj_drop: 释放内存
    // Verifier 确认: 每一个 bpf_obj_new 都有对应的 bpf_obj_drop 或转移
    bpf_obj_drop(d);

    return 0;
}

char _license[] SEC("license") = "GPL";
