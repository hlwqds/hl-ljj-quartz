// 02-kptr-xchg: bpf_kptr_xchg 原子交换 — 连接跟踪器
//
// 对应文档 Section 4 - bpf_kptr_xchg：原子交换
//
// 演示:
// - bpf_obj_new 分配连接对象
// - bpf_kptr_xchg 原子替换 Map 中的旧连接
// - 处理旧连接 (bpf_obj_drop)
// - bpf_spin_lock 保护并发访问

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

typedef __u16 u16;
typedef __u32 u32;
typedef __u64 u64;

// kfunc 声明
extern void *bpf_obj_new_impl(u64 local_type_id, void *meta) __weak __ksym;
extern void bpf_obj_drop_impl(void *p, void *meta) __weak __ksym;

#define bpf_obj_new(type) ((type *)bpf_obj_new_impl(bpf_core_type_id_local(type), NULL))
#define bpf_obj_drop(kptr) bpf_obj_drop_impl((void *)(kptr), NULL)

// 连接信息
struct conn {
    u32 src_ip;
    u32 dst_ip;
    u16 src_port;
    u16 dst_port;
    u64 last_seen;
};

// Map 值: 包含 spin_lock + kptr
struct map_value {
    struct bpf_spin_lock lock;
    struct conn __kptr *conn_ptr;  // kptr: 存储 BPF 堆分配的连接对象
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, u32);
    __type(value, struct map_value);
} conntrack SEC(".maps");

SEC("fentry/do_sys_openat2")
int update_conntrack(u64 *ctx)
{
    u32 key = bpf_get_current_pid_tgid() >> 32;

    // 1. 分配新连接对象 (所有权: 当前函数)
    struct conn *new_conn = bpf_obj_new(typeof(*new_conn));
    if (!new_conn)
        return 0;

    new_conn->src_ip = key;
    new_conn->dst_ip = 0;
    new_conn->last_seen = bpf_ktime_get_ns();

    // 2. 查找 Map
    struct map_value *v = bpf_map_lookup_elem(&conntrack, &key);
    if (!v) {
        // Map 中没有该 key，直接释放
        bpf_obj_drop(new_conn);
        return 0;
    }

    // 3. 原子交换: bpf_kptr_xchg 自身是原子操作，不需要 spin_lock
    //    注意: spin_lock 内不能调用其他 helper (只能访问被锁保护的 map 值)
    struct conn *old_conn = bpf_kptr_xchg(&v->conn_ptr, new_conn);

    // 4. 必须处理旧连接! (所有权已转移到当前函数)
    if (old_conn) {
        bpf_obj_drop(old_conn);
    }

    return 0;
}

char _license[] SEC("license") = "GPL";
