// 03-ringbuf-reserve: Ring Buffer 正确用法
//
// 对应文档 Section 5.4
//
// 正确的 Reserve-Submit 模式:
//   reserve → 填充 → submit (提交给用户态)
//   或:      reserve → 填充 → discard (丢弃，不提交)

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct event {
    u32 pid;
    u64 timestamp;
};

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 256 * 1024);  // 256 KB
} events SEC(".maps");

SEC("fentry/do_sys_openat2")
int ringbuf_good(u64 *ctx)
{
    // Step 1: Reserve 空间 (非阻塞)
    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (!e)
        return 0;  // Buffer 满，丢弃此事件

    // Step 2: 填充数据 (直接写入预留内存，无需 copy)
    e->pid = bpf_get_current_pid_tgid() >> 32;
    e->timestamp = bpf_ktime_get_ns();

    // Step 3: Submit — 让用户态可以读取
    bpf_ringbuf_submit(e, 0);  // ✅ 提交给用户态 ringbuf_reader

    return 0;
}

char _license[] SEC("license") = "GPL";
