// 04-path-explosion: 路径爆炸 (对比实验)
//
// 对应文档 Section 5.2
//
// kernel 6.19 的 CFG-aware pruning 能高效处理大部分分支模式。
// 本实验对比两种写法的验证效率差异。
//
// bad:  嵌套 if × 15 层，无 early return → 2^15 = 32768 条路径
// good: 子函数封装 → 每个函数独立验证

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

typedef __u32 u32;
typedef __u64 u64;

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 64);
    __type(key, u32);
    __type(value, u64);
} stats_map SEC(".maps");

// ❌ 15 层嵌套 if，无 early return
// 理论路径: 2^15 = 32,768 条
// 每层 ~15 条 insns → 总 processed insns ≈ 15 * 32768 = 491,520
SEC("fentry/do_sys_openat2")
int explosion_bad(u64 *ctx)
{
    u32 flags = bpf_get_prandom_u32();
    u64 sum = 0;

    if (flags & 1) { sum += bpf_get_prandom_u32();
        if (flags & 2) { sum += bpf_get_prandom_u32();
            if (flags & 4) { sum += bpf_get_prandom_u32();
                if (flags & 8) { sum += bpf_get_prandom_u32();
                    if (flags & 16) { sum += bpf_get_prandom_u32();
                        if (flags & 32) { sum += bpf_get_prandom_u32();
                            if (flags & 64) { sum += bpf_get_prandom_u32();
                                if (flags & 128) { sum += bpf_get_prandom_u32();
                                    if (flags & 256) { sum += bpf_get_prandom_u32();
                                        if (flags & 512) { sum += bpf_get_prandom_u32();
                                            if (flags & 1024) { sum += bpf_get_prandom_u32();
                                                if (flags & 2048) { sum += bpf_get_prandom_u32();
                                                    if (flags & 4096) { sum += bpf_get_prandom_u32();
                                                        if (flags & 8192) { sum += bpf_get_prandom_u32();
                                                            if (flags & 16384) { sum += bpf_get_prandom_u32();
                                                                sum += 100;
                                                            } else { sum += 1; }
                                                        } else { sum += 1; }
                                                    } else { sum += 1; }
                                                } else { sum += 1; }
                                            } else { sum += 1; }
                                        } else { sum += 1; }
                                    } else { sum += 1; }
                                } else { sum += 1; }
                            } else { sum += 1; }
                        } else { sum += 1; }
                    } else { sum += 1; }
                } else { sum += 1; }
            } else { sum += 1; }
        } else { sum += 1; }
    } else { sum += 1; }

    // 强制使用 sum 防止优化
    u32 key = 0;
    u64 *v = bpf_map_lookup_elem(&stats_map, &key);
    if (v)
        *v = sum;

    return 0;
}

char _license[] SEC("license") = "GPL";
