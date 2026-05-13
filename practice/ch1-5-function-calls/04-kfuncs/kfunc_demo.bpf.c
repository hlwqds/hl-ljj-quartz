// 04-kfuncs: kfuncs 与弱链接
//
// 对应文档 Section 5 - kfuncs：下一代内核交互标准
//
// 演示:
// - kfunc 调用 (通过 BTF 类型检查，非 Helper 的整数 ID)
// - kfunc 声明方式: extern + __weak __ksym
// - bpf_ksym_exists: 运行时检查 kfunc 是否存在
// - 与 Helper 的对比: BTF 类型 vs 整数 ID

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

typedef __u32 u32;
typedef __u64 u64;

// kfunc 声明 — __weak __ksym 表示内核可能不支持此 kfunc
// bpf_obj_new_impl: 通过 BTF type ID 在 BPF 堆上分配对象
extern void *bpf_obj_new_impl(u64 local_type_id, void *meta) __weak __ksym;
extern void bpf_obj_drop_impl(void *p, void *meta) __weak __ksym;

// bpf_ksym_exists 检查 kfunc 是否存在于当前内核
// 来自 bpf_helpers.h: 返回 1 表示存在，0 表示不存在

struct my_node {
    u32 value;
};

#define bpf_obj_new(type) ((type *)bpf_obj_new_impl(bpf_core_type_id_local(type), NULL))
#define bpf_obj_drop(kptr) bpf_obj_drop_impl((void *)(kptr), NULL)

// 注意: kfunc 调用需要 fentry/fexit 程序类型 (kprobe 不支持)
SEC("fentry/do_sys_openat2")
int kfunc_demo(u64 *ctx)
{
    // bpf_ksym_exists: 检查 bpf_obj_new_impl 是否可用
    // 对应文档 Section 5.5: __weak 弱链接机制
    if (!bpf_ksym_exists(bpf_obj_new_impl)) {
        // 内核不支持 bpf_obj_new，静默返回
        return 0;
    }

    // kfunc: bpf_obj_new — 通过 BTF 获取类型信息
    // 对应文档 Section 5.4: KF_ACQUIRE 标志
    struct my_node *n = bpf_obj_new(typeof(*n));
    if (!n)
        return 0;

    n->value = bpf_get_prandom_u32();

    // bpf_obj_drop: 释放对象
    // 对应文档 Section 5.4: KF_RELEASE 标志
    bpf_obj_drop(n);

    return 0;
}

char _license[] SEC("license") = "GPL";
