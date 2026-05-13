// 03-field-exists (bad): 硬编码偏移量 — 非 CO-RE 方式
//
// 对应文档 Section 4 (BTF_CORE_READ 与 CO-RE 编程 API)
//
// ❌ 问题: 用 bpf_probe_read_kernel + 硬编码偏移量读取字段
//    偏移量在不同内核版本间会变化:
//      开发机 5.15:  task->comm 在 offset 556
//      生产机 6.19:  task->comm 在 offset 2120
//    硬编码 556 在 6.19 上读到的是完全错误的数据
//
// ✅ 正确做法: 用 BPF_CORE_READ (见 field_exists_good.bpf.c)
//    BPF_CORE_READ 自动适配不同内核的字段偏移量

#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

struct event {
    u32 pid;
    char comm[16];
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

SEC("fentry/do_sys_openat2")
int on_open_bad(struct pt_regs *ctx)
{
    struct task_struct *task = bpf_get_current_task_btf();
    if (!task)
        return 0;

    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    // ❌ 硬编码偏移量 — 在不同内核上会读到错误数据
    // 这个偏移量只在特定内核版本上正确
    // 换一个内核版本，偏移量就变了
    void *comm_ptr = (void *)task + 556;  // 硬编码 comm 偏移量
    bpf_probe_read_kernel(e->comm, sizeof(e->comm), comm_ptr);

    // pid 也用硬编码偏移
    void *pid_ptr = (void *)task + 944;   // 硬编码 pid 偏移量
    bpf_probe_read_kernel(&e->pid, sizeof(e->pid), pid_ptr);

    bpf_ringbuf_submit(e, 0);
    return 0;
}

char _license[] SEC("license") = "GPL";
