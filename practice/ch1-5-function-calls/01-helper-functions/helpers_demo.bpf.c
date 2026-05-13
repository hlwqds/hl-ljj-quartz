// 01-helper-functions: Helper Functions 演示
//
// 对应文档 Section 2 - Helper Functions：内核的标准 API
//
// 演示多种 Helper 调用:
// - bpf_ktime_get_ns: 获取时间戳 (0 参数)
// - bpf_get_prandom_u32: 获取随机数 (0 参数)
// - bpf_map_lookup_elem: Map 查找 (2 参数)
// - bpf_map_update_elem: Map 更新 (4 参数)
// - bpf_get_current_pid_tgid: 获取进程 ID (0 参数)

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);
    __type(value, __u64);
} counter_map SEC(".maps");

SEC("kprobe/do_sys_openat2")
int helpers_demo(struct pt_regs *ctx)
{
    // Helper 1: bpf_ktime_get_ns — 0 参数
    u64 timestamp = bpf_ktime_get_ns();

    // Helper 2: bpf_get_current_pid_tgid — 0 参数
    u32 pid = bpf_get_current_pid_tgid() >> 32;

    // Helper 3: bpf_get_prandom_u32 — 0 参数，用于采样
    u32 rand = bpf_get_prandom_u32();

    // 只采样 1% 的调用
    if (rand % 100 != 0)
        return 0;

    // Helper 4: bpf_map_lookup_elem — 2 参数 (Map 指针, Key 指针)
    u32 key = pid;
    u64 *count = bpf_map_lookup_elem(&counter_map, &key);

    if (count) {
        // 原子递增
        __sync_fetch_and_add(count, 1);
    } else {
        // Helper 5: bpf_map_update_elem — 4 参数
        u64 init = 1;
        bpf_map_update_elem(&counter_map, &key, &init, BPF_ANY);
    }

    return 0;
}

char _license[] SEC("license") = "GPL";
