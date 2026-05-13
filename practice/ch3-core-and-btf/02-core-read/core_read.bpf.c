// 02-core-read: BPF_CORE_READ 跨版本读取内核结构体
//
// 对应文档 Section 4 (BTF_CORE_READ 与 CO-RE 编程 API)
//
// BPF_CORE_READ 的核心价值:
//   开发机内核: task->comm offset = 556
//   生产机内核: task->comm offset = 1216
//   BPF_CORE_READ 在加载时自动修正偏移量，无需重编译
//
// 本程序:
//   1. fentry/do_sys_openat2 获取 task_struct 指针
//   2. BPF_CORE_READ 读取 task->comm, task->pid
//   3. Ring Buffer 提交给用户态
//   4. run.sh 用 bpftool 展示 CO-RE 重定位记录

#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

// 事件结构
struct event {
    u32 pid;
    u32 ppid;
    char comm[16];
    u64 timestamp;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

SEC("fentry/do_sys_openat2")
int on_open(struct pt_regs *ctx)
{
    struct task_struct *task = bpf_get_current_task_btf();
    if (!task)
        return 0;

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    e->timestamp = bpf_ktime_get_ns();

    // BPF_CORE_READ: 自动适配不同内核的 task_struct 布局
    // 在编译机内核: LD [task+556] 读取 comm
    // 在目标机内核: libbpf 自动修正为 LD [task+1216]
    BPF_CORE_READ_INTO(&e->pid, task, pid);
    __builtin_memset(e->comm, 0, sizeof(e->comm));
    BPF_CORE_READ_INTO(&e->comm, task, comm);

    // 链式读取: task->real_parent->pid
    // 注意: BPF_CORE_READ 不做存在性检查，链式中任一字段不存在则加载失败
    // 必须用 bpf_core_field_exists 保护
    // 加载后 bpf_core_field_exists 被替换为常量 0 或 1，JIT 消除死分支 → 零指令开销
    e->ppid = 0;
    if (bpf_core_field_exists(task->real_parent)) {
        e->ppid = BPF_CORE_READ(task, real_parent, pid);
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

char _license[] SEC("license") = "GPL";
