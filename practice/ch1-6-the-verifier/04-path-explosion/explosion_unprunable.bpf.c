// gen_unprunable.py 25 — volatile 数组阻止 clang 扁平化
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
typedef __u32 u32; typedef __u64 u64;

struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_0 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_1 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_2 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_3 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_4 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_5 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_6 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_7 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_8 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_9 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_10 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_11 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_12 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_13 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_14 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_15 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_16 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_17 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_18 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_19 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_20 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_21 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_22 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_23 SEC(".maps");
struct { __uint(type, BPF_MAP_TYPE_HASH); __uint(max_entries, 1); __type(key, u32); __type(value, u64); } map_24 SEC(".maps");

SEC("fentry/do_sys_openat2")
int explosion_unprunable(u64 *ctx)
{
    u32 flags = bpf_get_prandom_u32();
    u32 key = 0;
    volatile u64 r[25];

    if (flags & (1 << 0)) {
            u64 *v = bpf_map_lookup_elem(&map_0, &key);
            r[0] = v ? *v : (u64)-1;
        } else {
            r[0] = 0;
        if (flags & (1 << 1)) {
                u64 *v = bpf_map_lookup_elem(&map_1, &key);
                r[1] = v ? *v : (u64)-1;
            } else {
                r[1] = 1;
            if (flags & (1 << 2)) {
                    u64 *v = bpf_map_lookup_elem(&map_2, &key);
                    r[2] = v ? *v : (u64)-1;
                } else {
                    r[2] = 2;
                if (flags & (1 << 3)) {
                        u64 *v = bpf_map_lookup_elem(&map_3, &key);
                        r[3] = v ? *v : (u64)-1;
                    } else {
                        r[3] = 3;
                    if (flags & (1 << 4)) {
                            u64 *v = bpf_map_lookup_elem(&map_4, &key);
                            r[4] = v ? *v : (u64)-1;
                        } else {
                            r[4] = 4;
                        if (flags & (1 << 5)) {
                                u64 *v = bpf_map_lookup_elem(&map_5, &key);
                                r[5] = v ? *v : (u64)-1;
                            } else {
                                r[5] = 5;
                            if (flags & (1 << 6)) {
                                    u64 *v = bpf_map_lookup_elem(&map_6, &key);
                                    r[6] = v ? *v : (u64)-1;
                                } else {
                                    r[6] = 6;
                                if (flags & (1 << 7)) {
                                        u64 *v = bpf_map_lookup_elem(&map_7, &key);
                                        r[7] = v ? *v : (u64)-1;
                                    } else {
                                        r[7] = 7;
                                    if (flags & (1 << 8)) {
                                            u64 *v = bpf_map_lookup_elem(&map_8, &key);
                                            r[8] = v ? *v : (u64)-1;
                                        } else {
                                            r[8] = 8;
                                        if (flags & (1 << 9)) {
                                                u64 *v = bpf_map_lookup_elem(&map_9, &key);
                                                r[9] = v ? *v : (u64)-1;
                                            } else {
                                                r[9] = 9;
                                            if (flags & (1 << 10)) {
                                                    u64 *v = bpf_map_lookup_elem(&map_10, &key);
                                                    r[10] = v ? *v : (u64)-1;
                                                } else {
                                                    r[10] = 10;
                                                if (flags & (1 << 11)) {
                                                        u64 *v = bpf_map_lookup_elem(&map_11, &key);
                                                        r[11] = v ? *v : (u64)-1;
                                                    } else {
                                                        r[11] = 11;
                                                    if (flags & (1 << 12)) {
                                                            u64 *v = bpf_map_lookup_elem(&map_12, &key);
                                                            r[12] = v ? *v : (u64)-1;
                                                        } else {
                                                            r[12] = 12;
                                                        if (flags & (1 << 13)) {
                                                                u64 *v = bpf_map_lookup_elem(&map_13, &key);
                                                                r[13] = v ? *v : (u64)-1;
                                                            } else {
                                                                r[13] = 13;
                                                            if (flags & (1 << 14)) {
                                                                    u64 *v = bpf_map_lookup_elem(&map_14, &key);
                                                                    r[14] = v ? *v : (u64)-1;
                                                                } else {
                                                                    r[14] = 14;
                                                                if (flags & (1 << 15)) {
                                                                        u64 *v = bpf_map_lookup_elem(&map_15, &key);
                                                                        r[15] = v ? *v : (u64)-1;
                                                                    } else {
                                                                        r[15] = 15;
                                                                    if (flags & (1 << 16)) {
                                                                            u64 *v = bpf_map_lookup_elem(&map_16, &key);
                                                                            r[16] = v ? *v : (u64)-1;
                                                                        } else {
                                                                            r[16] = 16;
                                                                        if (flags & (1 << 17)) {
                                                                                u64 *v = bpf_map_lookup_elem(&map_17, &key);
                                                                                r[17] = v ? *v : (u64)-1;
                                                                            } else {
                                                                                r[17] = 17;
                                                                            if (flags & (1 << 18)) {
                                                                                    u64 *v = bpf_map_lookup_elem(&map_18, &key);
                                                                                    r[18] = v ? *v : (u64)-1;
                                                                                } else {
                                                                                    r[18] = 18;
                                                                                if (flags & (1 << 19)) {
                                                                                        u64 *v = bpf_map_lookup_elem(&map_19, &key);
                                                                                        r[19] = v ? *v : (u64)-1;
                                                                                    } else {
                                                                                        r[19] = 19;
                                                                                    if (flags & (1 << 20)) {
                                                                                            u64 *v = bpf_map_lookup_elem(&map_20, &key);
                                                                                            r[20] = v ? *v : (u64)-1;
                                                                                        } else {
                                                                                            r[20] = 20;
                                                                                        if (flags & (1 << 21)) {
                                                                                                u64 *v = bpf_map_lookup_elem(&map_21, &key);
                                                                                                r[21] = v ? *v : (u64)-1;
                                                                                            } else {
                                                                                                r[21] = 21;
                                                                                            if (flags & (1 << 22)) {
                                                                                                    u64 *v = bpf_map_lookup_elem(&map_22, &key);
                                                                                                    r[22] = v ? *v : (u64)-1;
                                                                                                } else {
                                                                                                    r[22] = 22;
                                                                                                if (flags & (1 << 23)) {
                                                                                                        u64 *v = bpf_map_lookup_elem(&map_23, &key);
                                                                                                        r[23] = v ? *v : (u64)-1;
                                                                                                    } else {
                                                                                                        r[23] = 23;
                                                                                                    if (flags & (1 << 24)) {
                                                                                                            u64 *v = bpf_map_lookup_elem(&map_24, &key);
                                                                                                            r[24] = v ? *v : (u64)-1;
                                                                                                        } else {
                                                                                                            r[24] = 24;
                                                                                                        }
                                                                                                    }
                                                                                                }
                                                                                            }
                                                                                        }
                                                                                    }
                                                                                }
                                                                            }
                                                                        }
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    *(volatile u64 *)0 = 0;
    return 0;
}

char _license[] SEC("license") = "GPL";
