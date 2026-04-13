---
title: "DPDK 深度探索 ch46：eBPF 与 DPDK"
date: 2026-04-10 18:30:00
tags: [dpdk, ebpf, xdp, tc, bpf, datapath, offload, kernel]
description: "深入解析 DPDK eBPF：XDP、TC-BPF、BPF CO-RE、BPF 辅助函数、DPDK BPF 库与数据包处理"
---

# DPDK 深度探索 ch46：eBPF 与 DPDK

> [!abstract] 核心要点
> eBPF 是 Linux 内核的革命性技术。本章深入解析 eBPF 原理、XDP、TC-BPF、BPF CO-RE 与 DPDK 集成。

## 1. eBPF 概述

### 1.1 什么是 eBPF

```
eBPF (extended Berkeley Packet Filter):

┌─────────────────────────────────────────────────────────────┐
│                    eBPF 架构                                │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              User Space                               │  │
│  │  - clang/llvm 编译                                  │  │
│  │  - bpf() 系统调用                                   │  │
│  │  - BPF object 文件                                  │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              BPF Verifier                            │  │
│  │  - 安全检查                                          │  │
│  │  - 确定性验证                                       │  │
│  │  - 指令限制                                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              JIT Compiler                             │  │
│  │  - x86-64, arm64, etc.                              │  │
│  │  - Native code                                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Kernel Hooks                            │  │
│  │  - XDP (网卡)                                      │  │
│  │  - TC (qdisc)                                     │  │
│  │  - kprobe/uprobe                                  │  │
│  │  - tracepoint                                     │  │
│  │  - cgroup                                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 eBPF vs DPDK

```
┌─────────────────────────────────────────────────────────────┐
│                    eBPF vs DPDK                            │
│                                                              │
│  eBPF:                                                    │
│  - 内核空间运行                                            │
│  - 免虚拟机                                              │
│  - 可加载到内核                                           │
│  - 数据包在网卡处处理                                     │
│                                                              │
│  DPDK:                                                    │
│  - 用户空间运行                                            │
│  - 完全绕过内核                                           │
│  - 需要大页内存                                           │
│  - 独占 NIC                                              │
│                                                              │
│  组合使用:                                                │
│  - eBPF 用于快速路径、内核协作                            │
│  - DPDK 用于高性能数据平面                                │
└─────────────────────────────────────────────────────────────┘
```

## 2. XDP

### 2.1 XDP 概述

```
XDP (Express Data Path):

┌─────────────────────────────────────────────────────────────┐
│                    XDP 数据路径                             │
│                                                              │
│  NIC ──▶ Driver ──▶ XDP Program ──▶ 决定                    │
│                          │                                   │
│                          ├──▶ DROP                         │
│                          │                                   │
│                          ├──▶ PASS (内核)                  │
│                          │                                   │
│                          ├──▶ REDIRECT (另一 NIC/AF_XDP)   │
│                          │                                   │
│                          └──▶ TX (环回)                     │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 XDP 程序结构

```c
// XDP 程序
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>

SEC("xdp")
int
xdp_parser(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析 Ethernet
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;

    // 解析 IP
    if (eth->h_proto == htons(ETH_P_IP)) {
        struct iphdr *ip = (void *)(eth + 1);
        if ((void *)(ip + 1) > data_end)
            return XDP_DROP;

        // 获取源 IP
        __u32 src_ip = ip->saddr;

        // TCP 过滤
        if (ip->protocol == IPPROTO_TCP) {
            return XDP_PASS;
        }
    }

    return XDP_PASS;
}
```

### 2.3 XDP + DPDK

```bash
# 编译 XDP 程序
clang -O2 -target bpf -c xdp_kern.c -o xdp_kern.o

# 加载 XDP
ip link set eth0 xdp obj xdp_kern.o sec xdp

# 查看
ip link show eth0

# 卸载
ip link set eth0 xdp off
```

## 3. TC-BPF

### 3.1 TC 概述

```
TC (Traffic Control) + eBPF:

┌─────────────────────────────────────────────────────────────┐
│                    TC Ingress                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Kernel Netstack                          │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │           TC Ingress Hook                     │   │  │
│  │  │  - eBPF classifier                          │   │  │
│  │  │  - Can redirect to other devices            │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  │                      ↓                               │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │           TC Egress Hook                      │   │  │
│  │  │  - eBPF shaper                             │   │  │
│  │  │  - Can redirect                            │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 TC eBPF 程序

```c
// TC 分类器
SEC("tc")
int
tc_classify(struct __sk_buff *skb)
{
    // 读取数据
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_SHOT;

    // 根据源 MAC 分类
    if (eth->h_source[0] == 0x00) {
        // 设置 classid
        return TC_ACT_OK;
    }

    return TC_ACT_SHOT;
}

// TC action
SEC("tc")
int
tc_action(struct __sk_buff *skb)
{
    // 添加标记
    __u32 mark = 0x1234;
    bpf_skb_store_bytes(skb, 0, &mark, sizeof(mark), 0);

    return TC_ACT_OK;
}
```

## 4. DPDK BPF

### 4.1 DPDK BPF 库

```c
#include <rte_bpf.h>

// DPDK BPF 支持
// - 独立的 BPF VM
// - 可加载到 DPDK 应用
// - 无需内核
```

### 4.2 BPF 程序加载

```c
// DPDK BPF 初始化
int
init_bpf(void)
{
    // 创建 VM
    struct rte_bpf *bpf;

    // 编译 BPF
    struct rte_bpf_prm params = {
        .prog_func = 0,  // JIT 回调
        .prog_arg = NULL,
    };

    // 从 ELF 加载
    bpf = rte_bpf_elf_load("filter.o", "filter/0",
                           RTE_BPF_XDPOPS_ALL, socket_id);

    return bpf != NULL ? 0 : -1;
}
```

## 5. BPF CO-RE

### 5.1 CO-RE 概念

```
CO-RE (Compile Once - Run Everywhere):

问题：
- 内核数据结构在不同版本间变化
- BTF (BPF Type Format) 提供类型信息

解决方案：
- 编译时保留类型信息
- 运行时通过 BTF 重定位
```

### 5.2 CO-RE 使用

```c
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

// 读取内核结构体
struct task_struct {
    int pid;
    char comm[16];
};

SEC("tracepoint/syscalls/sys_enter_execve")
int
trace_execve(struct trace_event_raw_sys_enter *ctx)
{
    // CO-RE 读取
    struct task_struct *task = (struct task_struct *)
        bpf_get_current_task();

    // 安全读取 pid
    __u32 pid = BPF_CORE_READ(task, pid);

    // 安全读取 comm
    char comm[16];
    BPF_CORE_READ_INTO(&comm, task, comm);

    bpf_printk("execve: pid=%d comm=%s\n", pid, comm);

    return 0;
}
```

## 6. BPF Map

### 6.1 Map 类型

```
BPF Map 类型：

┌─────────────────────────────────────────────────────────────┐
│                    BPF Maps                                │
│                                                              │
│  1. Hash Map (bpf_map_lookup_elem)                        │
│     - 任意键值                                             │
│     - 平均 O(1)                                            │
│                                                              │
│  2. Array Map                                              │
│     - 整数索引                                             │
│     - O(1) 访问                                            │
│                                                              │
│  3. Per-CPU Map                                            │
│     - 每个 CPU 独立副本                                    │
│     - 无锁                                                  │
│                                                              │
│  4. LRU Hash Map                                           │
│     - 自动淘汰最旧                                         │
│     - 适合缓存                                             │
│                                                              │
│  5. Stack/Queue                                            │
│     - FIFO/LIFO                                           │
│     - 用于事件传递                                         │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Map 操作

```c
#include <bpf/bpf_map.h>

// 定义 Map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 1024);
    __type(key, __u32);      // IP
    __type(value, __u64);    // Counter
} packet_count SEC(".maps");

// 在程序中使用
SEC("xdp")
int
count_packets(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth = data;
    struct iphdr *ip = (void *)(eth + 1);

    __u32 key = ip->saddr;
    __u64 *count;

    // 查找
    count = bpf_map_lookup_elem(&packet_count, &key);

    if (count) {
        __sync_fetch_and_add(count, 1);
    } else {
        __u64 one = 1;
        bpf_map_update_elem(&packet_count, &key, &one, BPF_ANY);
    }

    return XDP_PASS;
}
```

## 7. 应用场景

### 7.1 XDP DDoS 防护

```c
// XDP DDoS 防护
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, 1000000);
    __type(key, __u32);
    __type(value, __u64);
} connection_limit SEC(".maps");

SEC("xdp")
int
ddos_filter(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth = data;
    struct iphdr *ip = (void *)(eth + 1);

    __u32 src_ip = ip->saddr;
    __u64 *cnt = bpf_map_lookup_elem(&connection_limit, &src_ip);

    if (!cnt) {
        __u64 one = 1;
        bpf_map_update_elem(&connection_limit, &src_ip, &one, BPF_ANY);
        return XDP_PASS;
    }

    // 限制速率
    if (*cnt > 10000) {
        return XDP_DROP;
    }

    __sync_fetch_and_add(cnt, 1);
    return XDP_PASS;
}
```

### 7.2 TC 流量整形

```c
// TC 流量整形
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 100);
    __type(key, __u32);    // priority
    __type(value, __u64);  // tokens
} token_bucket SEC(".maps");

SEC("tc")
int
rate_limit(struct __sk_buff *skb)
{
    __u32 priority = 0;
    __u64 *tokens = bpf_map_lookup_elem(&token_bucket, &priority);

    if (tokens && *tokens > 0) {
        (*tokens)--;
        return TC_ACT_OK;
    }

    return TC_ACT_SHOT;  // Drop
}
```

## 8. 总结

eBPF + DPDK：

```
组合架构：

┌─────────────────────────────────────────────────────────────┐
│                    eBPF + DPDK                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  XDP/eBPF (内核)                                     │  │
│  │  - 快速过滤                                         │  │
│  │  - 预处理                                           │  │
│  │  - DDoS 防护                                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  DPDK (用户空间)                                      │  │
│  │  - 高性能转发                                       │  │
│  │  - 复杂处理                                         │  │
│  │  - 加密/压缩                                       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

使用场景：

| 场景 | eBPF | DPDK |
|------|------|------|
| **包过滤** | ✅ XDP | ✅ |
| **防火墙** | ✅ TC | ✅ |
| **负载均衡** | ✅ XDP redirect | ✅ |
| **加密** | ❌ | ✅ |
| **高性能转发** | ❌ | ✅ |

---

## 参考资源

- [BPF Performance Tools](https://www.brendangregg.com/bpf-performance-tools-book.html)
- [XDP Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [DPDK BPF](https://doc.dpdk.org/guides/prog_guide/bpf_lib.html)
