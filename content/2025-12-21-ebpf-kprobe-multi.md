---
title: kprobe_multi：eBPF 批量追踪的高效利器
date: 2025-12-21 00:00:00
pin: true
tags: [ebpf, performance, kprobe, kprobe_multi]
---


# kprobe_multi：eBPF 批量追踪的高效利器

在 `fentry` 和标准 `kprobe` 之外，Linux 5.18 引入了一个名为 `kprobe_multi` 的新特性。它解决了在大规模追踪场景下（如 `pwru` 或系统级 profiler）面临的一个关键瓶颈：**挂载耗时**。

## 1. 为什么需要 kprobe_multi？

在 `kprobe_multi` 出现之前，如果你想追踪内核中的 1000 个函数，你主要有两种选择：

1.  **标准 kprobe**：创建 1000 个 `perf_event`，调用 1000 次 `ioctl` 或 `bpf_link_create`。
2.  **fentry**：为 1000 个函数创建 1000 个 BPF Trampoline（蹦床）。

**痛点**：
*   **挂载速度慢**：逐个挂载涉及大量的系统调用和内核对象分配。对于数千个探针，启动时间可能长达几秒甚至更久。
*   **资源消耗**：fentry 虽然运行时极快，但每个被追踪函数需要独立的 Trampoline 内存页。大规模使用时会显著增加内核内存占用。

## 2. 工作原理

`kprobe_multi` 基于内核的 `fprobe`（Function Probe）机制构建，而 `fprobe` 又是基于 `ftrace` 的。

1.  **批量接口**：它允许用户通过**单次** `bpf_link_create` 系统调用，传递一组目标函数（可以是符号名数组，也可以是地址数组）。
2.  **Ftrace 钩子**：内核利用 `ftrace` 的基础设施，在这些函数入口处插入回调。由于 `ftrace` 本身就是为了处理大量函数追踪设计的，因此扩展性极佳。
3.  **共享 BPF 程序**：所有被挂载的函数都运行**同一个** BPF 程序。程序可以通过上下文（Context）获取当前触发的函数地址（IP），从而区分具体是哪个函数被调用。

## 3. 性能特征

### 挂载性能 (Attach Performance)
这是 `kprobe_multi` 的杀手锏。
*   **kprobe/fentry**：线性增长。挂载 10,000 个函数可能需要 10+ 秒。
*   **kprobe_multi**：极快。挂载 10,000 个函数通常在毫秒级完成。

### 运行时开销 (Runtime Overhead)
*   **fentry**：最快（直接调用）。
*   **kprobe_multi**：中等。它利用了 `ftrace` 的 `save_regs` 机制，比基于 `int3` 异常的标准 `kprobe` 快很多，但略慢于 `fentry`。
*   **kprobe (legacy)**：最慢（异常处理）。

## 4. 代码示例 (libbpf)

在 libbpf 中使用 `kprobe_multi` 非常简单，通常通过 `SEC("kprobe.multi/...")` 定义。

```c
#include "vmlinux.h"
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_tracing.h>

char LICENSE[] SEC("license") = "Dual BSD/GPL";

// 挂载到所有以 "tcp_" 开头的内核函数
SEC("kprobe.multi/tcp_*")
int BPF_PROG(trace_tcp_functions)
{
    unsigned long ip = bpf_get_func_ip(ctx);
    
    // 你的逻辑...
    // bpf_printk("Function at %lx called\n", ip);
    
    return 0;
}
```

也可以在用户态显式指定函数列表：

```c
LIBBPF_OPTS(bpf_kprobe_multi_opts, opts);
const char *syms[] = { "tcp_v4_rcv", "tcp_v6_rcv", "ip_rcv" };

opts.syms = syms;
opts.cnt = 3;

link = bpf_program__attach_kprobe_multi_opts(prog, NULL, &opts);
```

## 5. 总结

`kprobe_multi` 填补了高性能追踪领域的一块拼图：

| 特性 | kprobe (Legacy) | fentry | kprobe_multi |
| :--- | :--- | :--- | :--- |
| **适用场景** | 少量、特定位置追踪 | 高频、单一/少量函数追踪 | **批量、通配符、全系统追踪** |
| **挂载速度** | 慢 | 慢 | **极快** |
| **运行时开销** | 高 | **极低** | 中低 |
| **内核版本** | 任意 | 5.5+ | 5.18+ |

对于像 `pwru` 这样需要 "Trace the world" 的工具，`kprobe_multi` 是平衡启动速度和运行性能的最佳选择。
