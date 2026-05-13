// 03-field-exists (good): BPF_CORE_READ + bpf_core_field_exists
//
// 对应文档 Section 4 (BTF_CORE_READ 与 CO-RE 编程 API)
//
// ✅ 正确做法:
//    1. BPF_CORE_READ 自动适配不同内核的字段偏移量
//    2. bpf_core_field_exists 处理跨版本字段差异
//    3. 编译一次，所有支持 BTF 的内核都能运行
//
// 对比 bad 版本:
//    bad:  bpf_probe_read_kernel + 硬编码偏移量 → 换内核就读错数据
//    good: BPF_CORE_READ → libbpf 自动修正偏移量 → 换内核也能正确读取

#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct event {
    u32 pid;
    char comm[16];
    u32 has_scx;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

SEC("fentry/do_sys_openat2")
int on_open_good(struct pt_regs *ctx)
{
    struct task_struct *task = bpf_get_current_task_btf();
    if (!task)
        return 0;

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    // ✅ BPF_CORE_READ: 自动适配不同内核的 task_struct 布局
    //    开发机 5.15: LD [task+556]
    //    生产机 6.19: libbpf 自动修正为 LD [task+2120]
    BPF_CORE_READ_INTO(&e->pid, task, pid);
    __builtin_memset(e->comm, 0, sizeof(e->comm));
    BPF_CORE_READ_INTO(&e->comm, task, comm);

    // ✅ bpf_core_field_exists: 处理跨版本字段差异
    //    sched_ext_entity 在 6.11+ 内核才有
    //    < 6.11 内核: if(0) → JIT 完全消除 → 零运行时开销
    //    >= 6.11 内核: if(1) → 保留分支
    e->has_scx = 0;
    if (bpf_core_field_exists(task->scx)) {
        e->has_scx = 1;
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

char _license[] SEC("license") = "GPL";
