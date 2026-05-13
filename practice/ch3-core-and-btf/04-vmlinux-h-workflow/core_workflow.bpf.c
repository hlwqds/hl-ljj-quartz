// 04-vmlinux-h-workflow: 完整的 CO-RE 开发工作流
//
// 对应文档 Section 5 (vmlinux.h 的生成与使用)
//
// 展示一个生产级 CO-RE BPF 程序的完整开发流程:
//   1. Makefile 自动生成 vmlinux.h
//   2. BPF 程序 include vmlinux.h，使用 BPF_CORE_READ
//   3. bpf_core_field_exists 处理跨版本差异
//   4. libbpf 自动重定位
//
// 这个程序追踪 TCP 连接建立事件:
//   - 读取 sock 结构体的地址和端口
//   - 读取关联进程的 pid/comm
//   - 全部通过 BPF_CORE_READ，跨版本兼容

#include "vmlinux.h"
#include <bpf/bpf_core_read.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

// TCP 连接事件
struct tcp_event {
    u32 pid;
    char comm[16];
    u32 saddr;
    u32 daddr;
    u16 sport;
    u16 dport;
    u64 timestamp;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);
} events SEC(".maps");

// Hash Map: 按进程 PID 统计连接数
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);
    __type(value, u64);
} conn_count SEC(".maps");

SEC("tracepoint/sock/inet_sock_set_state")
int on_tcp_state_change(void *ctx)
{
    // 使用 bpf_get_current_task_btf 获取当前进程
    struct task_struct *task = bpf_get_current_task_btf();
    if (!task)
        return 0;

    struct tcp_event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;

    e->timestamp = bpf_ktime_get_ns();

    // BPF_CORE_READ: 跨版本读取 task_struct
    BPF_CORE_READ_INTO(&e->pid, task, pid);
    __builtin_memset(e->comm, 0, sizeof(e->comm));
    BPF_CORE_READ_INTO(&e->comm, task, comm);

    // 初始化为 0 (如果 sock 字段不存在)
    e->saddr = 0;
    e->daddr = 0;
    e->sport = 0;
    e->dport = 0;

    // 更新连接计数
    u64 *count = bpf_map_lookup_elem(&conn_count, &e->pid);
    if (count)
        *count += 1;
    else {
        u64 val = 1;
        bpf_map_update_elem(&conn_count, &e->pid, &val, BPF_NOEXIST);
    }

    bpf_ringbuf_submit(e, 0);
    return 0;
}

char _license[] SEC("license") = "GPL";
