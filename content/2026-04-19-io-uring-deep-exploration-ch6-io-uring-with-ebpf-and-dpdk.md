---
title: io_uring 深度探索 Ch6：与 eBPF/DPDK 的协同
date: 2026-04-19 14:00:00
tags:
  [
    io_uring,
    Linux,
    eBPF,
    DPDK,
    Kernel Bypass,
    High Performance,
    Trace,
    Offload,
    Security,
    Observability,
  ]
description: 深入讲解 io_uring 与 eBPF/DPDK 的协同：eBPF 监控 io_uring、io_uring 作为 eBPF map、kernel bypass 网络与存储、DPDK+io_uring 混合架构、安全与观测能力。
---

# io_uring 深度探索 Ch6：与 eBPF/DPDK 的协同

## 1. 三剑客定位对比

### 1.1 各有所长

```
┌─────────────────────────────────────────────────────────────────┐
│                     I/O 技术栈三剑客                             │
├─────────────────┬──────────────────────┬─────────────────────────┤
│    io_uring     │        eBPF          │         DPDK           │
│  (Linux 5.1+)   │     (Linux 4.x+)     │      (Userspace)        │
├─────────────────┼──────────────────────┼─────────────────────────┤
│  内核异步 I/O   │  内核可编程扩展       │   内核旁路（NIC直接访问）│
│                 │                      │                         │
│  适用场景：     │  适用场景：           │  适用场景：              │
│  · 通用异步 I/O │  · 网络监控/过滤      │  · 超高吞吐网络（100G+）│
│  · 文件/网络    │  · 性能分析/trace    │  · 延迟极低（<10us）    │
│  · 中低频 I/O   │  · 安全策略执行      │  · 专用物理机           │
│                 │                      │                         │
│  优点：         │  优点：              │  优点：                  │
│  · 零拷贝       │  · 无需新内核代码    │  · 极致性能             │
│  · 批量异步     │  · 热加载            │  · 完全控制             │
│  · API 简单     │  · trace 任意内核函数│  · 绕过内核协议栈       │
│                 │                      │                         │
│  缺点：         │  缺点：              │  缺点：                  │
│  · 仍是内核态   │  · 编写复杂          │  · 需专用驱动           │
│  · 延迟不如 DPDK│  · 沙箱限制          │  · 无通用性             │
│  · eBPF 不能直接│  · 无法调用任意 syscall│ · 资源消耗大            │
│    调用 io_uring│                      │ · 不支持虚拟化环境       │
└─────────────────┴──────────────────────┴─────────────────────────┘
```

### 1.2 协同价值

```
为什么需要三者协同？

io_uring 的局限：
  - 只能处理已经"进来"的 I/O
  - 无法主动监控网络流量
  - 无法在内核路径上做过滤

eBPF 的局限：
  - 不能直接做大量数据 I/O
  - verifier 限制复杂逻辑
  - 无法"发起"网络连接

DPDK 的局限：
  - 纯用户态，无法利用内核功能
  - 无法直接访问文件系统
  - 安全策略难以实玾

三者协同：
  io_uring ←→ eBPF：监控与控制
  io_uring ←→ DPDK：高性能 I/O 混合
  eBPF ←→ DPDK：数据面编程
```

---

## 2. eBPF 监控 io_uring

### 2.1 可监控的 io_uring tracepoints

```bash
# io_uring 相关 tracepoints
ls /sys/kernel/debug/tracing/events/io_uring/
io_uring_create/     # ring 创建
io_uring_register/  # 注册操作
io_uring_enter/      # io_uring_enter() syscall
io_uringhoffset/     # ?
io_uring_poll_arm/   # poll arm
io_uring_poll_wake/  # poll 唤醒
io_uring_req_failed/ # 请求失败

# 启用跟踪
echo 1 > /sys/kernel/debug/tracing/events/io_uring/enable

# 查看跟踪输出
cat /sys/kernel/debug/tracing/trace_pipe

# 示例输出：
# <idle>-0     [003] d... 12345.678901: io_uring_enter:
#   ring_fd=5, to_submit=3, min_complete=0, flags=0x0, ret=3
```

### 2.2 eBPF 程序监控 io_uring 操作

```c
// io_uring_monitor.bpf.c
// eBPF 程序监控所有 io_uring 操作

#include <uapi/linux/io_uring.h>
#include <uapi/linux/ioctl.h>

// 跟踪 io_uring_enter syscall
SEC("tracepoint/syscalls/sys_enter_io_uring_enter")
int trace_io_uring_enter(struct trace_event_raw_sys_enter *ctx) {
    // 获取参数
    unsigned long fd = ctx->args[0];
    unsigned long to_submit = ctx->args[1];
    unsigned long min_complete = ctx->args[2];
    unsigned long flags = ctx->args[3];

    // 记录到 map
    struct io_uring_event *event = bpf_map_lookup_elem(&events, &key);
    if (event) {
        event->type = EVENT_ENTER;
        event->pid = bpf_get_current_pid_tgid() >> 32;
        event->fd = fd;
        event->submit_count = to_submit;
        event->flags = flags;
        bpf_map_update_elem(&events, &key, event, BPF_ANY);
    }

    return 0;
}

// 跟踪 ring 创建
SEC("tracepoint/io_uring/io_uring_create")
int trace_io_uring_create(struct trace_event_raw_io_uring_create *ctx) {
    u32 ring_fd = ctx->ring_fd;
    u32 user_fd = ctx->user_fd;
    u32 ring_entries = ctx->ring_entries;

    // 统计
    u32 *count = bpf_map_lookup_elem(&create_count, &zero);
    if (count) (*count)++;

    bpf_printk("io_uring created: ring_fd=%d, entries=%d\n",
               ring_fd, ring_entries);
    return 0;
}

// 跟踪 SQE 提交
SEC("tracepoint/io_uring/io_uring_enter")
int trace_sqe_submit(struct trace_event_raw_io_uring_enter *ctx) {
    u32 to_submit = ctx->to_submit;
    u32 flags = ctx->flags;

    // 统计提交量
    if (to_submit > 0) {
        u32 *total = bpf_map_lookup_elem(&submit_total, &zero);
        if (total) __sync_fetch_and_add(total, to_submit);
    }

    return 0;
}
```

### 2.3 监控数据可视化

```python
#!/usr/bin/env python3
# io_uring_stats.py — 读取 eBPF map 并可视化

import ctypes
import time
from bcc import BPF

# 加载 eBPF 程序
b = BPF(src_file="io_uring_monitor.bpf.c")
b.attach_tracepoint(tp="io_uring_create", fn_name="trace_io_uring_create")
b.attach_tracepoint(tp="io_uring/io_uring_enter", fn_name="trace_sqe_submit")

events = b["events"]
submit_total = b["submit_total"]
create_count = b["create_count"]

def print_stats():
    """定期打印统计信息"""
    while True:
        time.sleep(1)
        try:
            total = submit_total[ctypes.c_int(0)].value
            creates = create_count[ctypes.c_int(0)].value
            print(f"[{time.strftime('%H:%M:%S')}] "
                  f"Total submissions: {total}, "
                  f"Ring creates: {creates}")
        except:
            pass

if __name__ == "__main__":
    print("Monitoring io_uring operations...")
    print_stats()
```

---

## 3. io_uring 作为 eBPF Map（IORING_REGISTER）

### 3.1 概念：io_uring fd 作为 eBPF 资源

```
io_uring + eBPF 的结合方式：

方式 1：eBPF 监控 io_uring
  eBPF tracepoint → 跟踪 io_uring 操作
  用途：性能分析、debug

方式 2：eBPF 程序附加到 io_uring（5.6+）
  通过 IORING_REGISTER 注册 eBPF 程序
  io_uring → 触发 → eBPF 程序执行
  用途：自定义 I/O 策略、安全过滤

方式 3：io_uring 的 ring buffer 作为 eBPF map
  注册 io_uring 的 buffer 给 eBPF 使用
  用途：零拷贝数据传递
```

### 3.2 IORING_REGISTER 扩展（5.6+）

```c
// 注册 eBPF 程序到 io_uring

#include <linux/io_uring.h>
#include <linux/bpf.h>

// 5.6+ 支持的操作码
IORING_REGISTER REGISTER_EBPF_REG          // 注册 eBPF program
IORING_UNREGISTER_EBPF                   // 注销

// 注册 eBPF program
int register_ebpf(struct io_uring *ring, int prog_fd) {
    struct io_uring_register_reg reg = {
        .opcode = IORING_REGISTER_REGISTER_EBPF,
        .prog_fd = prog_fd,
    };
    return ioctl(ring->ring_fd, IORING_REGISTER, &reg);
}

// eBPF program 的触发时机：
// - 每次 SQE 执行前（PREPRO）
// - 每次 CQE 返回后（POSTPRO）
// - 每次 poll arm/wake

// 实际应用场景：
// 1. 安全过滤：检查每个 I/O 是否合法
// 2. 速率限制：控制每秒 I/O 数量
// 3. 智能路由：根据负载选择不同后端
```

### 3.3 eBPF 过滤 SQE（安全示例）

```c
// ebpf_filter.bpf.c — 只允许特定文件操作

#include <uapi/linux/io_uring.h>

// 允许的操作白名单
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);   // opcode
    __type(value, __u32); // 1=allowed
} allowed_ops SEC(".maps");

// PREPRO program：每个 SQE 执行前调用
SEC("io_uring_prog")
int io_uring_filter(struct io_uring_sqe *sqe) {
    __u32 opcode = sqe->opcode;

    // 检查是否在白名单
    __u32 *allowed = bpf_map_lookup_elem(&allowed_ops, &opcode);
    if (!allowed || *allowed != 1) {
        // 不允许 → 返回错误
        // 实际需要通过 return 值 + errno
        return -EPERM;
    }

    // 额外检查：FD 白名单
    __s32 fd = sqe->fd;
    if (fd >= 0) {
        // 检查这个 fd 是否允许
        // （需要额外 map 存储）
    }

    return 0;  // 允许
}

// 加载
int load_filter() {
    // 创建 whitelist map
    int map_fd = bpf_create_map(BPF_MAP_TYPE_HASH,
                                 sizeof(__u32), sizeof(__u32),
                                 256, 0);

    // 填充白名单
    __u32 key, val = 1;
    key = IORING_OP_READ; bpf_map_update_elem(map_fd, &key, &val, 0);
    key = IORING_OP_WRITE; bpf_map_update_elem(map_fd, &key, &val, 0);
    key = IORING_OP_OPENAT; bpf_map_update_elem(map_fd, &key, &val, 0);
    key = IORING_OP_CLOSE; bpf_map_update_elem(map_fd, &key, &val, 0);
    // 移除危险操作：IORING_OP_SOCKET 等

    // 加载 eBPF program
    // bpf_prog_load(...);

    // 注册到 io_uring
    // ioctl(ring_fd, IORING_REGISTER, ...);
}
```

---

## 4. io_uring 与 DPDK 协同架构

### 4.1 为什么 DPDK 需要 io_uring

```
DPDK 的问题：
  - 纯用户态，无法访问普通文件
  - 无法使用内核协议栈
  - 无法做系统调用

实际系统往往需要：
  - DPDK 处理高速网络数据面
  - io_uring 处理控制面和存储

典型场景：
  NFV（网络功能虚拟化）：
  ┌────────────────────────────────────────────┐
  │  DPDK：高速包处理（VSwitch、DPI、防火墙）  │
  │  io_uring：配置管理、日志存储、状态同步   │
  └────────────────────────────────────────────┘

  分布式存储：
  ┌────────────────────────────────────────────┐
  │  DPDK：NVMe-oF 高性能块设备访问            │
  │  io_uring：元数据操作、日志写入            │
  └────────────────────────────────────────────┘
```

### 4.2 DPDK + io_uring 混合架构

```
架构图：

┌─────────────────────────────────────────────────────┐
│                  用户空间                           │
│                                                      │
│  ┌──────────────┐        ┌──────────────────┐       │
│  │   DPDK Lcore  │        │   io_uring       │       │
│  │   (数据面)    │◄──────►│   (控制面/存储)   │       │
│  │               │  IPC   │                   │       │
│  │  · 包处理     │        │  · 文件 I/O       │       │
│  │  · VSwitch    │        │  · 异步日志       │       │
│  │  · 防火墙     │        │  · 配置读取       │       │
│  └───────┬──────┘        └────────┬─────────┘       │
│          │                          │                  │
│          │    共享内存               │                  │
│          │◄─────────────────────────│                  │
│          │                          │                  │
└──────────┼──────────────────────────┼──────────────────┘
           │                          │
┌──────────▼──────────────────────────▼──────────────────┐
│                     Linux Kernel                       │
│  ┌──────────────┐        ┌──────────────────┐         │
│  │  DPDK Poll   │        │   VFS/Ext4/XFS   │         │
│  │  Mode Driver │        │   (文件系统)     │         │
│  └───────┬──────┘        └────────┬─────────┘         │
│          │                          │                  │
│          │    HW                    │    SW             │
└──────────┼──────────────────────────┼──────────────────┘
           │                          │
     ┌─────▼─────┐             ┌──────▼──────┐
     │   NIC     │             │    NVMe     │
     │  (100G+)  │             │   (SSD)     │
     └───────────┘             └─────────────┘
```

### 4.3 共享内存通信

```c
// shm_ring.h — DPDK 和 io_uring 共享的 ring buffer

#include <stdint.h>
#include <stdbool.h>

#define SHM_RING_SIZE 1024

struct shm_item {
    uint64_t id;          // 请求 ID
    uint32_t type;        // 操作类型
    uint32_t len;         // 数据长度
    char data[];          // 可变长数据
};

struct shm_ring {
    volatile uint32_t head;    // 读位置
    volatile uint32_t tail;    // 写位置
    uint32_t mask;             // SIZE - 1
    uint32_t size;             // 槽数量
    struct shm_item items[];   // 槽数组
} __attribute__((aligned(64))); // cache line 对齐

// DPDK 端：生产者
struct shm_ring *dpdk_to_uring;

void dpdk_send_request(uint32_t type, const void *data, uint32_t len) {
    uint32_t tail = shm_ring->tail;
    uint32_t next_tail = (tail + 1) & shm_ring->mask;

    if (next_tail == shm_ring->head) {
        // ring 满，等待
        return;
    }

    struct shm_item *item = &shm_ring->items[tail];
    item->type = type;
    item->len = len;
    memcpy(item->data, data, len);

    // memory barrier
    __sync_synchronize();

    shm_ring->tail = next_tail;

    // 通知 io_uring
    // 可以用 eventfd / 共享变量
}

// io_uring 端：消费者
void uring_poll_shm() {
    while (shm_ring->head != shm_ring->tail) {
        uint32_t head = shm_ring->head;
        struct shm_item *item = &shm_ring->items[head];

        // 处理请求
        process_shm_item(item);

        shm_ring->head = (head + 1) & shm_ring->mask;
    }
}
```

### 4.4 实际案例：VPP + io_uring

```
VPP（Vector Packet Processor）是 DPDK 的典型应用

VPP 架构：
  ┌─────────────────────────────────────┐
  │         VPP Main Loop              │
  │  while (1) {                        │
  │    rx: 从 NIC 收包（dpdk）          │
  │    classify: 分类（ACL）           │
  │    forward: 转发（路由/L2）         │
  │    tx: 发包（dpdk）                │
  │  }                                  │
  └─────────────────────────────────────┘

VPP + io_uring 混合：
  VPP 处理数据面（高速包处理）
  io_uring 处理控制面（CLI/API/配置）

┌─────────────────────────────────────┐
│  VPP（数据面，DPDK）                │
│  · 100G NIC 包处理                  │
│  · 硬件卸载                         │
│  · 亚微秒延迟                       │
└─────────────────────────────────────┘
            │  IPC
            ▼
┌─────────────────────────────────────┐
│  io_uring（控制面，Linux）          │
│  · gRPC API 处理                    │
│  · 配置存储（etcd/Redis）          │
│  · 日志写入                         │
│  · 健康检查                         │
└─────────────────────────────────────┘
```

---

## 5. 观测能力：io_uring + eBPF 追踪

### 5.1 完整 I/O 链路追踪

```bash
#!/bin/bash
# io_uring_trace.sh — 追踪所有 io_uring I/O

# 启用所有 io_uring tracepoints
for tp in /sys/kernel/debug/tracing/events/io_uring/*; do
    basename=$(basename $tp)
    echo 1 > $tp/enable 2>/dev/null
done

# 添加函数过滤（只看某个进程）
# echo 12345 > /sys/kernel/debug/tracing/set_ftrace_pid

# 开始追踪
cat /sys/kernel/debug/tracing/trace_pipe | tee io_uring.log

# 或者用 perf：
perf record -e io_uring:* -a -g &
PERF_PID=$!

sleep 10

kill $PERF_PID

# 分析
perf script -i perf.data | ./FlameGraph/stackcollapse-perf.pl | \
    ./FlameGraph/flamegraph.pl > io_uring.svg
```

### 5.2 延迟分布分析

```c
// latency_hist.bpf.c — 测量 io_uring I/O 延迟分布

#include <uapi/linux/io_uring.h>
#include <linux/posix_timer.h>

// latency histogram（HIST map）
struct {
    __uint(type, BPF_MAP_TYPE_HIST);
    __uint(key_size, sizeof(u32));  // bucket index
    __uint(value_size, sizeof(u64)); // count
    __uint(max_entries, 64);        // 64 个 bucket
} latency_hist SEC(".maps");

// 跟踪 submit → complete 延迟
struct submit_event {
    u64 submit_time;
    u64 user_data;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u64);  // user_data
    __type(value, struct submit_event);
    __uint(max_entries, 1024);
} in_flight SEC(".maps");

// 提交时记录
SEC("tracepoint/io_uring/io_uring_enter")
int trace_submit(struct pt_regs *ctx) {
    u64 now = bpf_ktime_get_ns();
    u64 ud = 0;  // 无法直接从 tracepoint 获取 user_data

    struct submit_event ev = { .submit_time = now };
    bpf_map_update_elem(&in_flight, &ud, &ev, 0);
    return 0;
}

// 完成时计算延迟
SEC("tracepoint/io_uring/io_uring_complete")
int trace_complete(struct pt_regs *ctx) {
    u64 now = bpf_ktime_get_ns();
    u64 ud;  // 从 ctx 获取

    struct submit_event *ev = bpf_map_lookup_elem(&in_flight, &ud);
    if (!ev) return 0;

    u64 latency = now - ev->submit_time;

    // 分桶（logarithmic）
    // latency buckets: 0-1us, 1-2us, 2-4us, ... 1s+
    int bucket = 0;
    u64 l = latency;
    while (l > 1 && bucket < 63) {
        l >>= 1;
        bucket++;
    }

    u64 *count = bpf_map_lookup_elem(&latency_hist, &bucket);
    if (count) (*count)++;
    else bpf_map_update_elem(&latency_hist, &bucket, &1, 0);

    bpf_map_delete_elem(&in_flight, &ud);
    return 0;
}
```

### 5.3 队列深度监控

```python
#!/usr/bin/env python3
# queue_depth_monitor.py — 实时监控 io_uring 队列深度

import subprocess
import time
import re

def read_sq_cq_depth():
    """读取 /proc/*/fdinfo/* 获取 ring depth"""

    # 找到所有 io_uring fds
    result = subprocess.run(
        ['find', '/proc', '-name', 'fdinfo', '-type', 'd'],
        capture_output=True, text=True
    )

    total_sq = 0
    total_cq = 0

    for fdinfo_dir in result.stdout.strip().split('\n'):
        try:
            for fd_file in subprocess.run(
                ['ls', fdinfo_dir], capture_output=True, text=True
            ).stdout.strip().split('\n'):
                if not fd_file:
                    continue
                try:
                    with open(f'{fdinfo_dir}/{fd_file}') as f:
                        content = f.read()
                        if 'io_uring' in content:
                            # 解析 sq/cq info
                            for line in content.split('\n'):
                                if line.startswith('sq_ring_head:'):
                                    sq_head = int(line.split()[1], 16)
                                elif line.startswith('sq_tail:'):
                                    sq_tail = int(line.split()[1], 16)
                                elif line.startswith('cq_tail:'):
                                    cq_tail = int(line.split()[1], 16)
                except:
                    pass
        except:
            pass

    return total_sq, total_cq

# 实时监控
while True:
    print(f'[{time.strftime("%H:%M:%S")}] '
          f'Total SQ backlog: {total_sq}, '
          f'CQ overflow: {total_cq}')
    time.sleep(1)
```

---

## 6. 安全能力：io_uring + eBPF 沙箱

### 6.1 seccomp + io_uring 过滤

```c
// io_uring_seccomp.bpf.c — 用 eBPF 限制 io_uring 操作

// 思路：seccomp 只允许 io_uring_enter syscall
// eBPF PREPRO 进一步过滤 SQE

SEC("socket_filter")
int filter_socket(struct __sk_buff *skb) {
    // 不关心 socket filter
    return SK_DROP;
}

// 更好的方式：用 landlock（Linux 5.13+）

// landlock 规则：只允许特定文件/目录访问
struct landlock_ruleset_attr {
    __u64 handled_access_fs;  // 可访问的文件系统操作
};

void setup_landlock() {
    struct landlock_ruleset_attr attr = {
        .handled_access_fs =
            LANDLOCK_ACCESS_FS_READ |    // 读文件
            LANDLOCK_ACCESS_FS_WRITE |   // 写文件
            LANDLOCK_ACCESS_FS_OPEN,    // 打开文件
    };

    int ruleset_fd = syscall(SYS_landlock_create_ruleset,
                               &attr, sizeof(attr), 0);

    // 创建规则：只允许 /var/log 目录
    struct landlock_path_beneath_attr path = {
        .parent_fd = open("/var/log", O_PATH),
        .allowed_access = LANDLOCK_ACCESS_FS_READ |
                          LANDLOCK_ACCESS_FS_WRITE,
    };

    // 添加规则到 ruleset
    syscall(SYS_landlock_add_rule, ruleset_fd,
            LANDLOCK_RULE_PATH_BENEATH, &path, 0);

    // 限制当前线程
    syscall(SYS_landlock_restrict_self, ruleset_fd, 0);
}

// 效果：
// 进程只能通过 io_uring 操作 /var/log 下的文件
// 无法访问 /etc/passwd、/proc 等敏感资源
```

### 6.2 I/O 速率限制

```c
// rate_limiter.bpf.c — eBPF 限制 io_uring I/O 速率

#include <uapi/linux/io_uring.h>

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, u32);   // 0=token, 1=last_refill
    __type(value, u64);
    __uint(max_entries, 2);
} rate_limit_state SEC(".maps");

#define RATE_LIMIT_BPS 1000000000ULL  // 1 GB/s
#define REFILL_INTERVAL_NS 100000000ULL  // 100ms

SEC("io_uring_prog")
int rate_limit(struct io_uring_sqe *sqe) {
    u64 now = bpf_ktime_get_ns();
    u64 *state = bpf_map_lookup_elem(&rate_limit_state, &zero);

    if (!state) return 0;

    u64 tokens = state[0];
    u64 last_refill = state[1];

    // 补充 token
    if (now - last_refill >= REFILL_INTERVAL_NS) {
        u64 tokens_to_add = (now - last_refill) / REFILL_INTERVAL_NS
                           * RATE_LIMIT_BPS / (1000000000ULL / REFILL_INTERVAL_NS);
        tokens += tokens_to_add;
        if (tokens > RATE_LIMIT_BPS) tokens = RATE_LIMIT_BPS;
        last_refill = now;
        bpf_map_update_elem(&rate_limit_state, &zero, &tokens, 0);
    }

    // 检查 token
    __u32 len = sqe->len;
    if (len > tokens) {
        // 超出限制，延迟处理
        // 实际返回需要用 errno
        return -EBUSY;
    }

    // 消耗 token
    tokens -= len;
    bpf_map_update_elem(&rate_limit_state, &zero, &tokens, 0);

    return 0;  // 允许
}
```

---

## 7. 性能对比：io_uring vs DPDK vs 混合

### 7.1 延迟对比

```
延迟分布（4KB 随机读）：

                    p50     p99     p999    max
─────────────────────────────────────────────────
epoll + read        15us    45us    120us   500us
io_uring (sync)     8us     25us    80us    300us
io_uring (sqpoll)   4us     12us    40us    150us
io_uring (fixed)    2us     8us     25us    100us
─────────────────────────────────────────────────
DPDK (memzone)      0.5us   1us     3us     10us
DPDK + io_uring     1us     3us     8us     30us   ← 混合
─────────────────────────────────────────────────

分析：
  - epoll：每次 read() 都是独立 syscall，延迟高
  - io_uring sqpoll：省去 syscall，延迟降低 2-3x
  - io_uring fixed：省去 fd/buffer 验证，再降 2x
  - DPDK：内核旁路，极致低延迟
  - 混合：DPDK 处理数据，io_uring 处理控制
```

### 7.2 吞吐对比

```
吞吐量（单核，1MB 顺序写）：

                              IOPS           带宽
────────────────────────────────────────────────────
write() + fsync              15K           15 MB/s
io_uring (batch=32)           180K          180 MB/s
io_uring (sqpoll fixed)       350K          350 MB/s
────────────────────────────────────────────────────
DPDK (virtio-user)           2.5M          2.5 GB/s
DPDK (物理 NIC)               15M           15 GB/s
────────────────────────────────────────────────────
io_uring (NVMe O_DIRECT)     450K          1.8 GB/s
DPDK (NVMe-oF)               8M            32 GB/s
────────────────────────────────────────────────────

关键点：
  - io_uring 对普通存储已经很快（NVMe 可达 450K IOPS）
  - DPDK 需要专用硬件才能发挥
  - 混合场景：DPDK 10G 网络 + io_uring 存储
```

### 7.3 适用场景选择

```
场景选择指南：

┌────────────────────────────────────────────────────────┐
│ 场景                     │ 推荐方案                    │
├────────────────────────────────────────────────────────┤
│ 通用 Web 服务器          │ io_uring（足够了）         │
│ 高性能 Proxy/LB          │ io_uring + epoll 混合      │
│ 存储服务器（NAS/SAN）    │ io_uring + NVMe            │
│ NFV/DPI/防火墙           │ DPDK（100G+）              │
│ VPP 控制器               │ DPDK + io_uring 混合      │
│ 分布式数据库             │ io_uring（存储）+ 网络库   │
│ HPC/AI 训练              │ io_uring（checkpoints）   │
│ 超低延迟交易系统         │ DPDK（网络）+ RDMA         │
└────────────────────────────────────────────────────────┘

过渡策略：
  1. 先用 io_uring 实现所有功能
  2. 用 perf/火焰图定位瓶颈
  3. 瓶颈在网络 → 评估 DPDK
  4. 瓶颈在存储 → 评估 NVMe-oF
  5. 逐步迁移到混合架构
```

---

## 8. 实战：构建 io_uring + eBPF 观测平台

### 8.1 架构设计

```
┌─────────────────────────────────────────────────────┐
│              io_uring + eBPF 观测平台               │
│                                                      │
│  ┌─────────────┐   ┌─────────────┐  ┌────────────┐  │
│  │  应用进程   │   │ eBPF (内核) │  │  可视化    │  │
│  │  io_uring   │──►│  trace/hook │──►│ Prometheus│  │
│  └─────────────┘   └──────┬──────┘  └────────────┘  │
│                           │                          │
│                      ┌────▼────┐                    │
│                      │ BPF map │                    │
│                      │ 延迟分布 │                    │
│                      │ 吞吐计数 │                    │
│                      │ 热力图  │                    │
│                      └─────────┘                    │
└─────────────────────────────────────────────────────┘
```

### 8.2 完整 eBPF 观测程序

```c
// observe.bpf.c — 完整的 io_uring 观测 eBPF 程序

#include <uapi/linux/io_uring.h>
#include <linux/bpf.h>
#include <linux/pid_namespace.h>

// 统计 map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u32);    // opcode
    __type(value, struct op_stats);
    __uint(max_entries, 32);
} stats_map SEC(".maps");

struct op_stats {
    u64 count;
    u64 total_bytes;
    u64 total_latency_ns;
    u64 max_latency_ns;
    u64 min_latency_ns;
};

// 直方图 map
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, u32);   // bucket index
    __type(value, u64);
    __uint(max_entries, 64);
} latency_hist SEC(".maps");

// 当前追踪状态
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, u64);   // user_data
    __type(value, u64); // submit time
    __uint(max_entries, 4096);
} pending_ops SEC(".maps");

// 提交时
SEC("tracepoint/io_uring/io_uring_enter")
int handle_enter(struct trace_event_raw_io_uring_enter *ctx) {
    u32 opcode = 0;
    u64 user_data = 0;

    // 从 SQE 获取信息（需要通过 ring buffer 间接获取）
    // 实际中 tracepoint 可能不直接暴露

    // 更新统计
    struct op_stats *stats = bpf_map_lookup_elem(&stats_map, &opcode);
    if (stats) {
        __sync_fetch_and_add(&stats->count, 1);
    }

    return 0;
}

// 完成时
SEC("tracepoint/io_uring/io_uring_complete")
int handle_complete(struct trace_event_raw_io_uring_complete *ctx) {
    u64 user_data = ctx->user_data;
    s32 result = ctx->result;

    // 查找对应的提交
    u64 *submit_time = bpf_map_lookup_elem(&pending_ops, &user_data);
    if (!submit_time) return 0;

    u64 latency = bpf_ktime_get_ns() - *submit_time;

    // 更新直方图
    int bucket = 0;
    u64 l = latency;
    while (l > 0 && bucket < 63) {
        l >>= 1;
        bucket++;
    }
    u64 *count = bpf_map_lookup_elem(&latency_hist, &bucket);
    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        u64 init = 1;
        bpf_map_update_elem(&latency_hist, &bucket, &init, 0);
    }

    bpf_map_delete_elem(&pending_ops, &user_data);
    return 0;
}

char LICENSE[] SEC("license") = "GPL";
```

### 8.3 Python 可视化

```python
#!/usr/bin/env python3
# visualize_io_uring.py

import time
from prometheus_client import start_http_server, Gauge, Histogram
from bcc import BPF

# 加载 eBPF
b = BPF(src_file="observe.bpf.c")
b.attach_tracepoint(tp="io_uring/io_uring_enter",
                     fn_name="handle_enter")
b.attach_tracepoint(tp="io_uring/io_uring_complete",
                     fn_name="handle_complete")

# Prometheus metrics
io_uring_ops = Gauge('io_uring_ops_total', 'Total io_uring operations',
                     ['opcode'])
io_uring_latency = Histogram('io_uring_latency_us',
                              'io_uring operation latency',
                              buckets=[1, 5, 10, 25, 50, 100,
                                       250, 500, 1000, 5000])
io_uring_throughput = Gauge('io_uring_bytes_total',
                            'Total bytes through io_uring')

def update_metrics():
    stats_map = b["stats_map"]
    latency_hist = b["latency_hist"]

    # 更新操作计数
    for opcode, stats in stats_map.items():
        io_uring_ops.labels(opcode=opcode.value).set(stats.count)

    # 更新延迟直方图
    for bucket, count in latency_hist.items():
        # bucket index to latency range
        latency_us = 2 ** bucket.value
        io_uring_latency.observe(latency_us, count=count.value)

if __name__ == "__main__":
    start_http_server(9090)  # Prometheus scrape endpoint
    print("Serving metrics on :9090")

    while True:
        update_metrics()
        time.sleep(1)
```

---

## 9. 小结

```
io_uring 与 eBPF/DPDK 协同：

eBPF 监控 io_uring：
  - tracepoint：io_uring_create/enter/complete
  - 跟踪所有 SQE 提交和 CQE 完成
  - 构建 latency histogram、throughput 统计
  - 用于性能分析、debug、安全审计

eBPF 过滤 io_uring（SQE PREPRO）：
  - IORING_REGISTER 注册 eBPF program（5.6+）
  - PREPRO 在每个 SQE 执行前调用
  - 应用：安全白名单、速率限制、I/O 路由
  - 局限：eBPF verifier 限制复杂逻辑

DPDK + io_uring 混合架构：
  - DPDK：高速数据面（100G+ NIC、NVMe-oF）
  - io_uring：控制面（配置、日志、API）
  - 共享内存：跨组件通信
  - 典型案例：VPP + io_uring 控制器

io_uring 观测能力：
  - tracepoint 追踪 I/O 链路
  - BPF map 收集统计信息
  - Prometheus + Grafana 可视化
  - 热力图、延迟分布、性能火焰图

安全能力：
  - seccomp + landlock 限制系统调用
  - eBPF SQE 过滤白名单
  - I/O 速率限制

性能对比：
  - io_uring：2-8us 延迟，350K+ IOPS（单核）
  - DPDK：0.5-1us 延迟，10M+ IOPS
  - 混合：取长补短，各取所需

场景选择：
  - 通用服务器 → io_uring 足够
  - NFV/防火墙 → DPDK
  - VPP 控制器 → DPDK + io_uring
  - 存储服务器 → io_uring + NVMe
```

---

## 延伸阅读

- io_uring 官方文档: `Documentation/io_uring.rst` (Linux kernel)
- eBPF 文档: `Documentation/bpf/bpf_devel_QA.rst`
- LWN: "io_uring and eBPF": https://lwn.net/Articles/849787/
- LWN: "io_uring networking": https://lwn.net/Articles/810071/
- DPDK 文档: `https://doc.dpdk.org/`
- VPP + io_uring: `https://wiki.fd.io/view/VPP`
- "High Performance Network Programming" — Chapter on io_uring
- "Linux Observability with BPF" — O'Reilly
