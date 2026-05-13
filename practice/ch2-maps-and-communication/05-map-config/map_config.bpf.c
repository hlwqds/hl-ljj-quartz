// 05-map-config: Map 作为配置下发通道
//
// 对应文档 Section 7 (内核态-用户态通信模式)
//
// Map 的核心价值之一: 用户态写配置，BPF 程序读配置。
// 本程序展示:
//   1. BPF 程序从 Map 读取配置 (allowed_pid)
//   2. run.sh 用 bpftool map update 写入配置
//   3. BPF 程序根据配置做过滤
//
// 这是生产环境中最常见的 Map 用法:
//   - 用户态控制台修改配置 → 即时生效，无需重载 BPF 程序
//   - Cilium / Falco / Pixie 都用这个模式

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

// 配置 Map: 用户态写入的配置项
struct config {
    u32 allowed_pid;   // 只跟踪这个 PID 的 open 调用 (0 = 全部)
    u32 min_bytes;     // 只记录大于此大小的文件
    u64 timestamp;     // 配置最后更新时间
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, struct config);
} config_map SEC(".maps");

// 统计 Map: BPF 程序写入的统计数据
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, u32);    // pid
    __type(value, u64);  // open 次数
} stats_map SEC(".maps");

SEC("tracepoint/syscalls/sys_enter_openat")
int on_open(void *ctx)
{
    u32 key_idx = 0;
    struct config *cfg = bpf_map_lookup_elem(&config_map, &key_idx);
    if (!cfg)
        return 0;

    // 从配置读取过滤条件
    u32 my_pid = bpf_get_current_pid_tgid() >> 32;
    if (cfg->allowed_pid != 0 && cfg->allowed_pid != my_pid)
        return 0;

    // 更新统计 (key = pid)
    u64 *count = bpf_map_lookup_elem(&stats_map, &my_pid);
    if (count)
        *count += 1;

    return 0;
}

char _license[] SEC("license") = "GPL";
