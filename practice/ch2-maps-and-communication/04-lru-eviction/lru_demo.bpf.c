// 04-lru-eviction: LRU Hash Map 自动淘汰
//
// 对应文档 Section 6.1 (LRU Hash Map)
//
// LRU_HASH 在 Map 满时自动淘汰最久未访问的条目。
// 本程序 max_entries = 4，每次 fentry 调用插入一个条目。
// 多次调用后，最老的条目会被自动淘汰。
//
// 用法:
//   1. 加载程序
//   2. 多次 cat /proc/loadavg (触发 do_sys_openat2)
//   3. bpftool map dump 查看只剩 4 条

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

// LRU Hash Map: 最多 4 条，超出自动淘汰最久未访问的
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 4);
    __type(key, u32);
    __type(value, u64);
} lru_map SEC(".maps");

SEC("fentry/do_sys_openat2")
int lru_insert(u64 *ctx)
{
    // 用 pid 低 8 位作为 key (0-255 范围，但 map 只能存 4 条)
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    u32 key = pid & 0xFF;

    // lookup 会刷新访问时间 (防止刚访问的条目被淘汰)
    u64 *existing = bpf_map_lookup_elem(&lru_map, &key);
    if (existing) {
        *existing += 1;
    } else {
        // key 不存在 → 插入
        // 如果 map 已满 → 自动淘汰最久未访问的条目
        u64 val = bpf_ktime_get_ns();
        long err = bpf_map_update_elem(&lru_map, &key, &val, BPF_ANY);
        if (err) {
            // LRU 会自动淘汰，但极端情况下仍可能失败
        }
    }

    return 0;
}

char _license[] SEC("license") = "GPL";
