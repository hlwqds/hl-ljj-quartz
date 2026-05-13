// 03-ringbuf-reserve: Ring Buffer Reserve-Submit 模式
//
// 对应文档 Section 5.4 (Ring Buffer 代码实战)
//
// Ring Buffer 写入三步曲:
//   1. bpf_ringbuf_reserve()  — 预留空间 (非阻塞，满时返回 NULL)
//   2. 填充数据              — 直接写入预留的内存
//   3. bpf_ringbuf_submit()   — 提交给用户态 (或 bpf_ringbuf_discard 丢弃)
//
// 如果 reserve 后不 submit/discard → Verifier 报错 (内存泄漏)。

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
int ringbuf_leak_bad(u64 *ctx)
{
    // Reserve 空间
    struct event *e = bpf_ringbuf_reserve(&events, sizeof(*e), 0);
    if (e) {
        e->pid = bpf_get_current_pid_tgid() >> 32;
        e->timestamp = bpf_ktime_get_ns();

        // ❌ 没有 bpf_ringbuf_submit 或 bpf_ringbuf_discard!
        // 预留的内存永远不会被释放 → Verifier 拒绝
    }

    return 0;
}

char _license[] SEC("license") = "GPL";
