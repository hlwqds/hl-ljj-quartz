// 05-helper-type-mismatch: 正确的 Helper 参数类型
//
// 对应文档 Section 6.4
//
// bpf_map_lookup_elem 的签名:
//   void *bpf_map_lookup_elem(struct bpf_map *map, const void *key)
// 第二个参数必须是指向 key 的指针。

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1);
    __type(key, u32);
    __type(value, u64);
} counter_map SEC(".maps");

SEC("fentry/do_sys_openat2")
int type_good(u64 *ctx)
{
    u32 key = 0;

    // ✅ 传 &key (pointer to stack) — 正确
    u64 *value = bpf_map_lookup_elem(&counter_map, &key);

    if (!value)
        return 0;

    *value += 1;
    return 0;
}

char _license[] SEC("license") = "GPL";
