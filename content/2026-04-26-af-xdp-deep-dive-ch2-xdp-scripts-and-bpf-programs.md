---
title: AF_XDP 深度探索 Ch2：XDP 脚本与 BPF 程序
date: 2026-04-26 09:00:00
tags:
  [
    AF_XDP,
    XDP,
    eBPF,
    BPF CO-RE,
    libbpf,
    clang,
    iproute2,
    Packet Filtering,
    Load Balancer,
    DDoS Protection,
    Traffic Control,
    XDP Programs,
    BTF,
    Map,
    Tail Call,
  ]
description: 深入实战 XDP BPF 程序：开发环境搭建、程序结构、Map 使用、Tail Call、libbpf 骨架、加载与调试，以及典型应用场景（防火墙/负载均衡/DDoS防御）。
---

# AF_XDP 深度探索 Ch2：XDP 脚本与 BPF 程序

## 1. 开发环境搭建

### 1.1 依赖工具

```bash
#!/bin/bash
# setup_xdp_env.sh — XDP 开发环境搭建

echo "=== XDP 开发环境搭建 ==="

# 1. 检查内核版本（需要 4.18+）
echo "内核版本: $(uname -r)"
if [[ $(uname -r | cut -d. -f2) -lt 18 ]]; then
    echo "需要内核 4.18+ 才能完整支持 XDP"
fi

# 2. 安装编译工具
apt-get update && apt-get install -y \
    clang llvm lld \
    libbpf-dev \
    linux-headers-$(uname -r) \
    libpcap-dev \
    gcc multilib \
    python3 python3-pip \
    git make

# 3. 安装 bpftool（内核源码编译）
cd /tmp
git clone --depth 1 --branch v6.8 https://github.com/torvalds/linux.git
cd linux/tools/bpf/bpftool
make
make install

# 4. 安装 iproute2（支持 XDP）
apt-get install -y iproute2 || {
    cd /tmp
    git clone --depth 1 https://github.com/shemminger/iproute2.git
    cd iproute2
    ./configure
    make
    make install
}

# 5. 验证安装
echo ""
echo "=== 验证安装 ==="
echo "clang: $(clang --version | head -1)"
echo "llvm: $(llvm-strip --version | head -1)"
echo "bpftool: $(bpftool version 2>/dev/null || echo 'not found')"
```

### 1.2 内核配置检查

```bash
#!/bin/bash
# check_xdp_support.sh — 检查 XDP 支持

echo "=== 检查 XDP 支持 ==="

# 检查网卡队列
echo "网卡队列:"
ip link show | grep -E "mtu|xdp" | head -10

# 检查 XDP 状态
echo ""
echo "XDP 状态:"
for iface in $(ls /sys/class/net/); do
    if [ -f /sys/class/net/$iface/queues/rx-0/xdp_rxq_info ]; then
        echo "  $iface: 支持 XDP"
    fi
done

# 检查 bpf 系统调用
echo ""
echo "BPF 系统调用: $(cat /proc/sys/kernel/bpf_stats_enabled 2>/dev/null || echo 'N/A')"

# 检查 bpf Jit
echo "BPF JIT: $(cat /proc/sys/net/core/bpf_jit_enable)"

# 检查 hugepages
echo "Hugepages: $(cat /proc/meminfo | grep Hugepages)"

# ethtool 查看驱动支持
echo ""
echo "驱动 XDP 支持: $(ethtool -h 2>/dev/null | grep -i xdp || echo 'N/A')"
```

---

## 2. BPF 程序结构

### 2.1 XDP 程序基本框架

```c
// xdp_basic.c — XDP BPF 程序基本框架

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>

/*
 * XDP 程序必须返回以下值之一：
 *   - XDP_PASS  (1)  交给内核继续处理
 *   - XDP_DROP  (2)  丢弃数据包
 *   - XDP_REDIRECT (3) 重定向到其他接口或 AF_XDP
 *   - XDP_TX    (4)  从原网卡发送出去
 *   - XDP_ABORTED (5) 异常丢弃（统计在 XDP_ABORTED）
 *
 * SEC("xdp") 指定程序类型
 */

/*
 * BPF 辅助函数（bpf_*）是唯一安全的内核调用方式
 * 不可直接调用内核函数，必须通过辅助函数
 */

// 许可（每个 XDP 程序必须有）
SEC("xdp")
int xdp_pass_all(struct xdp_md *ctx)
{
    return XDP_PASS;
}

// 丢弃所有 TCP
SEC("xdp")
int xdp_drop_tcp(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析 Ethernet 头
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    // 只处理 IPv4
    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    // 解析 IP 头
    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // 丢弃 TCP
    if (iph->protocol == IPPROTO_TCP)
        return XDP_DROP;

    return XDP_PASS;
}

// license 必须为 GPL（否则无法使用某些辅助函数）
char _license[] SEC("license") = "GPL";
```

### 2.2 BPF 辅助函数详解

```
BPF 辅助函数分类：

┌────────────────────────────────────────────────────────────────┐
│                    BPF 辅助函数类别                            │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│  1. 读写数据包                                                  │
│     bpf_printk(fmt, ...)        — 调试输出到 trace_pipe       │
│     bpf_skb_load_bytes(skb, o, buf, len)                      │
│     bpf_skb_store_bytes(skb, o, buf, len)                     │
│     bpf_skb_change_tail(skb, len)                             │
│                                                                │
│  2. XDP 专用                                                    │
│     bpf_redirect(map_id, flags)   — 重定向到其他接口          │
│     bpf_xdp_adjust_head(xdp, delta)                          │
│     bpf_xdp_adjust_tail(xdp, delta)                           │
│     bpf_xdp_load_bytes(xdp, offset, buf, len)                 │
│                                                                │
│  3. Map 操作                                                    │
│     bpf_map_lookup_elem(map, key)                              │
│     bpf_map_update_elem(map, key, value, flags)               │
│     bpf_map_delete_elem(map, key)                              │
│     bpf_map_push_elem(map, value)                             │
│                                                                │
│  4. 计数/统计                                                   │
│     bpf_per_cpu() — per-CPU 计数器                            │
│     bpf_ringbuf_output() — ring buffer 输出                  │
│                                                                │
│  5. 尾部调用                                                    │
│     bpf_tail_call(ctx, prog_array, index)                    │
│                                                                │
│  6. 时间戳                                                      │
│     bpf_ktime_get_ns()                                        │
│     bpf_ktime_get_boot_ns()                                    │
│                                                                │
│  7. 随机数                                                      │
│     bpf_get_prandom_u32()                                      │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

### 2.3 BPF Map 类型

```
常用 BPF Map 类型：

┌────────────────────────────────────────────────────────────────┐
│  Map 类型            │  用途            │  示例               │
├────────────────────────────────────────────────────────────────┤
│  BPF_MAP_TYPE_HASH   │  K-V 查找       │  IP 黑名单          │
│  BPF_MAP_TYPE_ARRAY  │  数组（O(1)）   │  计数器数组         │
│  BPF_MAP_TYPE_PERCPU_HASH │ per-CPU │  per-CPU 统计      │
│  BPF_MAP_TYPE_LRU_HASH   │  LRU 缓存   │  连接跟踪         │
│  BPF_MAP_TYPE_DEVMAP    │  设备重定向  │  负载均衡          │
│  BPF_MAP_TYPE_CPUMAP    │  CPU 重定向  │  RSS               │
│  BPF_MAP_TYPE_PROG_ARRAY│  Tail Call   │  策略路由          │
│  BPF_MAP_TYPE_RINGBUF   │  Ring Buffer │  事件通知          │
│  BPF_MAP_TYPE_SOCKMAP   │  Socket 映射 │  转发              │
│  BPF_MAP_TYPE_XSKMAP    │  AF_XDP 映射 │  XSK 转发          │
└────────────────────────────────────────────────────────────────┘
```

---

## 3. BPF Map 实战

### 3.1 统计计数器

```c
// xdp_stats.c — XDP 统计计数器

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>

/*
 * 定义 BPF Map
 * bpf_map_def（老式）或 BTF 定义（新式）
 */

// 定义 Hash Map：统计各协议包数
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 256);
    __type(key, __u32);         // 协议号
    __type(value, __u64);       // 计数
} stats_map SEC(".maps");

// 定义 Array Map：统计总包数
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u64);
} packet_counts SEC(".maps");

// 统计程序
SEC("xdp")
int xdp_count_pkts(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 总包数 +1
    __u32 total_key = 0;
    __u64 *total = bpf_map_lookup_elem(&packet_counts, &total_key);
    if (total)
        __sync_fetch_and_add(total, 1);

    // 解析 Ethernet
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    // 只处理 IP
    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    // 解析 IP 头
    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // 协议统计
    __u32 proto_key = iph->protocol;
    __u64 *count = bpf_map_lookup_elem(&stats_map, &proto_key);
    if (count)
        __sync_fetch_and_add(count, 1);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

### 3.2 IP 黑名单

```c
// xdp_blacklist.c — IP 黑名单过滤

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>

// IP 黑名单 Map
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);  // 64K IP
    __type(key, __u32);          // IP 地址（网络序）
    __type(value, __u8);         // 标志（1=黑名单）
} blacklist_map SEC(".maps");

// 白名单（优先级更高）
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, __u8);
} whitelist_map SEC(".maps");

// 丢弃匹配黑名单的 IP
SEC("xdp")
int xdp_filter_ip(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析 Ethernet + IP
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    __u32 src_ip = iph->saddr;
    __u32 dst_ip = iph->daddr;

    // 检查白名单（优先）
    if (bpf_map_lookup_elem(&whitelist_map, &src_ip))
        return XDP_PASS;
    if (bpf_map_lookup_elem(&whitelist_map, &dst_ip))
        return XDP_PASS;

    // 检查黑名单
    if (bpf_map_lookup_elem(&blacklist_map, &src_ip))
        return XDP_DROP;
    if (bpf_map_lookup_elem(&blacklist_map, &dst_ip))
        return XDP_DROP;

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

### 3.3 负载均衡（Redirection）

```c
// xdp_lb.c — XDP 负载均衡

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>

// 目标设备 Map
struct {
    __uint(type, BPF_MAP_TYPE_DEVMAP);
    __uint(max_entries, 32);
    __type(key, __u32);           // ifindex
    __type(value, struct bpf_devmap_val);  // 目标设备
} device_map SEC(".maps");

// 后端数组（真实服务器）
struct backend {
    __u32 ip;
    __u16 port;
};

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 16);
    __type(key, __u32);
    __type(value, struct backend);
} backend_array SEC(".maps");

// 连接数 Map（简单 round-robin）
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 1);
    __type(key, __u32);
    __type(value, __u32);  // 当前索引
} lb_state SEC(".maps");

SEC("xdp")
int xdp_lb(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析 Ethernet + IP
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // Round-robin 选择后端
    __u32 state_key = 0;
    __u32 *idx = bpf_map_lookup_elem(&lb_state, &state_key);
    if (!idx)
        return XDP_PASS;

    __u32 backend_idx = *idx % 16;
    struct backend *be = bpf_map_lookup_elem(&backend_array, &backend_idx);
    if (!be)
        return XDP_PASS;

    // 更新索引
    __sync_fetch_and_add(idx, 1);

    // 修改目的 MAC（实际需要 ARP 或 MAC 学习）
    // 这里简化处理，直接重定向
    // 真实场景需要修改 IP/MAC + NAT

    // 重定向到对应网卡
    return bpf_redirect(0, 0);  // 0 = 透传重定向
}

char _license[] SEC("license") = "GPL";
```

---

## 4. Tail Call（尾部调用）

### 4.1 Tail Call 原理

```
Tail Call（尾部调用）：

  · 允许一个 BPF 程序调用另一个 BPF 程序
  · 不占用栈空间（普通函数调用占用）
  · 类似 switch-case，分发到不同处理逻辑
  · 常用于：策略路由、分层处理、模块化

限制：
  · 最多 32 层嵌套（MAX_TAIL_CALLS）
  · 目标程序必须是同一类型
  · 无法返回值（直接跳转执行目标）

工作原理：

  ┌──────────────────────────────────────────────────────────┐
  │  XDP 程序 A                                                │
  │    │                                                      │
  │    ├─ 协议判断 ── TCP ──► Tail Call ──► TCP 处理程序    │
  │    │                   (index=0)                          │
  │    │                                                      │
  │    ├─ 协议判断 ── UDP ──► Tail Call ──► UDP 处理程序    │
  │    │                   (index=1)                          │
  │    │                                                      │
  │    └─ 协议判断 ── OTHER ──► Tail Call ──► 其他处理程序  │
  │                        (index=2)                         │
  └──────────────────────────────────────────────────────────┘
```

### 4.2 Tail Call 实现

```c
// xdp_tailcall.c — Tail Call 示例

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

/*
 * 策略：HTTP 放行，SSH 限流，其他丢弃
 *
 * 程序结构：
 *   xdp_main (入口) → 根据协议 tail_call 到具体处理程序
 *   xdp_handle_tcp
 *   xdp_handle_udp
 *   xdp_handle_other
 */

// PROG_ARRAY Map（存放各处理程序的 fd）
struct {
    __uint(type, BPF_MAP_TYPE_PROG_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u32);  // program fd
} prog_array SEC(".maps");

// 入口程序
SEC("xdp")
int xdp_main(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析 Ethernet
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    // 解析 IP
    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // 解析 TCP/UDP
    if (iph->protocol == IPPROTO_TCP) {
        // tail_call index=0
        bpf_tail_call(ctx, &prog_array, 0);
    } else if (iph->protocol == IPPROTO_UDP) {
        // tail_call index=1
        bpf_tail_call(ctx, &prog_array, 1);
    } else {
        // tail_call index=2
        bpf_tail_call(ctx, &prog_array, 2);
    }

    // 如果 tail_call 失败，继续执行
    return XDP_PASS;
}

// TCP 处理程序（index=0）
SEC("xdp")
int xdp_handle_tcp(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    struct tcphdr *tcph = data + sizeof(*eth) + sizeof(*iph);
    if ((void *)(tcph + 1) > data_end)
        return XDP_PASS;

    // HTTP (80) 放行
    if (tcph->dest == htons(80))
        return XDP_PASS;

    // SSH (22) 限流（随机丢包 50%）
    if (tcph->dest == htons(22)) {
        if (bpf_get_prandom_u32() % 2 == 0)
            return XDP_DROP;
        return XDP_PASS;
    }

    // 其他 TCP 放行
    return XDP_PASS;
}

// UDP 处理程序（index=1）
SEC("xdp")
int xdp_handle_udp(struct xdp_md *ctx)
{
    // DNS 放行，其他丢弃
    // ... 类似处理
    return XDP_PASS;
}

// 其他协议处理（index=2）
SEC("xdp")
int xdp_handle_other(struct xdp_md *ctx)
{
    // ICMP 放行，其他丢弃
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

---

## 5. libbpf 骨架与加载

### 5.1 编译 BPF 程序

```bash
#!/bin/bash
# compile_xdp.sh — 编译 XDP 程序

XDP_PROG="xdp_basic"

# 方式 1：clang 直接编译
clang -O2 -target bpf -Wall \
    -I/usr/include/$(uname -m)-linux-gnu \
    -c ${XDP_PROG}.c -o ${XDP_PROG}.o

# 验证目标文件
file ${XDP_PROG}.o
llvm-objdump -D ${XDP_PROG}.o | head -30

# 查看 section
llvm-objdump -h ${XDP_PROG}.o

# 方式 2：使用 Makefile
# （见下方）
```

```makefile
# Makefile — XDP 程序编译

ARCH := $(shell uname -m)
KVER := $(shell uname -r)
KDIR := /lib/modules/$(KVER)/build

CLANG ?= clang
LLVM_STRIP ?= llvm-strip

SRC := $(wildcard *.c)
OBJ := $(SRC:.c=.o)

# 头文件路径
INCLUDES := -I/usr/include/$(ARCH)-linux-gnu

.PHONY: all clean load unload

all: $(OBJ)

%.o: %.c
	$(CLANG) -O2 -target bpf -Wall $(INCLUDES) -c $< -o $@

# 剥离调试信息（减小体积）
strip: $(OBJ)
	$(LLVM_STRIP) -g $^

# 加载（需要 root）
load: xdp_basic.o
	sudo ip link set dev eth0 xdp obj xdp_basic.o sec xdp
	sudo ip link set dev eth0 xdp object xdp_basic.o sec xdp_drop_tcp

# 卸载
unload:
	sudo ip link set dev eth0 xdp off

# 查看状态
show:
	ip link show eth0

# 查看 XDP 日志
log:
	sudo cat /sys/kernel/debug/tracing/trace_pipe | grep xdp

# 统计
stats:
	sudo cat /sys/class/net/eth0/statistics/rx_xdp_*
	bpftool net show
```

### 5.2 libbpf 骨架生成

```bash
#!/bin/bash
# 生成 libbpf 骨架

# 使用 bpftool gen skeleton
bpftool gen skeleton xdp_basic.o > xdp_basic.skel.h

# 或者使用 pahole
pahole -h xdp_basic.o
```

```c
// xdp_with_skel.c — 使用 libbpf 骨架

#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include "xdp_basic.skel.h"

static volatile int running = 1;

void signal_handler(int sig) { running = 0; }

int main(int argc, char **argv)
{
    struct xdp_basic_bpf *skel;
    int err;

    // 打开/加载 BPF 程序
    skel = xdp_basic_bpf__open_and_load();
    if (!skel) {
        fprintf(stderr, "Failed to open BPF skeleton\n");
        return 1;
    }

    // 附加到网卡
    err = xdp_basic_bpf__attach(skel);
    if (err) {
        fprintf(stderr, "Failed to attach BPF: %d\n", err);
        goto cleanup;
    }

    printf("XDP 程序已加载\n");
    printf("按 Ctrl-C 退出\n");

    // 设置信号处理
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);

    // 主循环
    while (running) {
        sleep(1);

        // 读取 Map 数据
        // ... bpf_map__lookup ...
    }

cleanup:
    xdp_basic_bpf__destroy(skel);
    return 0;
}
```

### 5.3 完整 libbpf 应用

```c
// xdp_app.c — 完整的 libbpf 应用（包含 Map 操作）

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <net/if.h>
#include <linux/if_link.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>
#include "xdp_stats.skel.h"

#define ETH_MAC {0x00, 0x11, 0x22, 0x33, 0x44, 0x55}

struct config {
    char *ifname;
    int ifindex;
    int xdp_flags;
    int prog_fd;
};

static void print_stats(int stats_map_fd)
{
    // 读取统计 Map
    // 注意：需要与 BPF 程序的 key/value 类型匹配
    // ...
    printf("\n=== XDP 统计 ===\n");
    printf("Total:   %llu\n", 0ULL);
    printf("TCP:     %llu\n", 0ULL);
    printf("UDP:     %llu\n", 0ULL);
    printf("Other:   %llu\n", 0ULL);
}

static int load_bpf_object(struct xdp_stats_bpf **pskel, struct config *cfg)
{
    struct xdp_stats_bpf *skel;
    struct bpf_program *prog;
    struct bpf_object *obj;
    int err;

    // 打开骨架
    skel = xdp_stats_bpf__open();
    if (!skel) {
        fprintf(stderr, "Failed to open skeleton\n");
        return -1;
    }

    // 配置加载参数
    obj = skel->obj;

    // 加载
    err = xdp_stats_bpf__load(obj);
    if (err) {
        fprintf(stderr, "Failed to load BPF: %d\n", err);
        goto out;
    }

    // 获取 program fd
    prog = bpf_object__find_program_by_name(obj, "xdp_count_pkts");
    if (!prog) {
        fprintf(stderr, "Failed to find program\n");
        err = -1;
        goto out;
    }
    cfg->prog_fd = bpf_program__fd(prog);

    *pskel = skel;
    return 0;

out:
    xdp_stats_bpf__destroy(skel);
    return err;
}

static int attach_bpf(struct config *cfg)
{
    // 使用 libbpf 高级 API 附加
    cfg->xdp_flags = XDP_FLAGS_DRV_MODE;  // 原生模式（驱动支持）
    // cfg->xdp_flags = XDP_FLAGS_SKB_MODE;  // 通用模式

    int err = bpf_set_link_xdp_fd(cfg->ifindex, cfg->prog_fd, cfg->xdp_flags);
    if (err < 0) {
        fprintf(stderr, "Failed to set XDP: %d\n", err);
        return err;
    }
    return 0;
}

int main(int argc, char **argv)
{
    struct xdp_stats_bpf *skel = NULL;
    struct config cfg = {0};
    int stats_map_fd;
    int err;

    if (argc != 2) {
        fprintf(stderr, "Usage: %s <ifname>\n", argv[0]);
        return 1;
    }

    cfg.ifname = argv[1];
    cfg.ifindex = if_nametoindex(cfg.ifname);
    if (!cfg.ifindex) {
        perror("if_nametoindex");
        return 1;
    }

    printf("加载 XDP 到 %s (ifindex=%d)\n", cfg.ifname, cfg.ifindex);

    // 加载 BPF
    err = load_bpf_object(&skel, &cfg);
    if (err < 0) return 1;

    // 附加
    err = attach_bpf(&cfg);
    if (err < 0) goto cleanup;

    // 获取统计 Map fd
    stats_map_fd = bpf_map__fd(skel->maps.stats_map);
    if (stats_map_fd < 0) {
        fprintf(stderr, "Failed to get map fd\n");
        goto cleanup;
    }

    printf("XDP 已运行，按 Ctrl-C 退出\n");

    // 主循环
    while (1) {
        sleep(5);
        print_stats(stats_map_fd);
    }

cleanup:
    // 分离 XDP
    bpf_set_link_xdp_fd(cfg.ifindex, -1, cfg.xdp_flags);
    xdp_stats_bpf__destroy(skel);
    return 届 0;
}
```

---

## 6. BPF CO-RE（跨内核移植）

### 6.1 CO-RE 原理

```
BPF CO-RE（Compile Once - Run Everywhere）：

  问题：不同内核的 BPF 辅助函数、struct 布局可能不同
  解决：编译时记录字段偏移，内核加载时重定位

┌────────────────────────────────────────────────────────────────┐
│  传统 BPF：                                                      │
│    编译时假设特定内核 struct 布局                               │
│    内核升级可能崩溃                                              │
│                                                                │
│  CO-RE：                                                         │
│    使用 __attribute__((preserve_access_index))               │
│    编译时生成 BTF（BPF Type Format）                           │
│    内核加载时自动调整偏移                                        │
└────────────────────────────────────────────────────────────────┘

CO-RE 核心宏：
  BPF_PROG — 定义 XDP 程序
  BPF_MAP — 定义 Map
  bpf_member_exists — 检查结构体字段是否存在
  bpf_core_read — 安全读取（带重定位）
```

### 6.2 CO-RE 示例

```c
// xdp_core.c — CO-RE 兼容程序

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_core_read.h>

/*
 * CO-RE 特性：
 * 1. 使用 bpf_core_read 代替直接指针访问
 * 2. 使用 BPF_CORE_READ 宏读取嵌套结构
 * 3. 自动处理内核版本差异
 */

// 不使用 CO-RE（旧式，依赖编译时内核头文件）
SEC("xdp/no_core")
int xdp_no_core(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    struct ethhdr *eth = ctx->data;

    // 直接访问，可能在不同内核版本崩溃
    if (eth + 1 > data_end)
        return XDP_PASS;

    return XDP_PASS;
}

// 使用 CO-RE（安全，跨内核）
SEC("xdp/core")
int xdp_with_core(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    // 安全读取，支持跨内核
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    // CO-RE 读取 IP 头（安全）
    struct iphdr *iph = data + sizeof(*eth);

    // 检查边界（CO-RE 会在运行时检查）
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // 使用 BPF_CORE_READ 安全读取
    __u32 protocol;
    bpf_core_read(&protocol, sizeof(protocol), &iph->protocol);

    // 读取源 IP
    __u32 src_ip;
    bpf_core_read(&src_ip, sizeof(src_ip), &iph->saddr);

    return XDP_PASS;
}

// 读取复杂嵌套结构（COHTTP 示例）
SEC("xdp/http")
int xdp_parse_http(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // ... 解析到 TCP 层
    struct tcphdr *tcph = data + sizeof(struct ethhdr) + sizeof(struct iphdr);

    if ((void *)(tcph + 1) > data_end)
        return XDP_PASS;

    // 检查 HTTP 端口
    __u16 dest_port;
    bpf_core_read(&dest_port, sizeof(dest_port), &tcph->dest);

    if (dest_port == htons(80) || dest_port == htons(8080)) {
        // 解析 HTTP 首部
        __u8 *payload = data + sizeof(struct ethhdr) + sizeof(struct iphdr) +
                        sizeof(struct tcphdr);

        // ... 检查 HTTP GET/POST 等
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

---

## 7. 典型应用场景

### 7.1 DDoS 防御

```c
// xdp_ddos.c — DDoS 防御系统

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

#define MAX_ENTRIES 65536
#define RATE_LIMIT 1000  // 每秒包数

// 源 IP 统计
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key, __u32);   // 源 IP
    __type(value, __u64); // 时间戳 + 计数
} src_ip_map SEC(".maps");

// 目的 IP 统计
struct {
    __uint(type, BPF_MAP_TYPE_LRU_HASH);
    __uint(max_entries, MAX_ENTRIES);
    __type(key, __u32);   // 目的 IP
    __type(value, __u64); // 计数
} dst_ip_map SEC(".maps");

// 配置 Map（可运行时修改）
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 4);
    __type(key, __u32);
    __type(value, __u32);
} config_map SEC(".maps");

// LRU Hash 实现（简化的滑动窗口）
static __u64 get_packet_rate(__u32 ip)
{
    __u64 *val = bpf_map_lookup_elem(&src_ip_map, &ip);
    if (!val)
        return 0;
    return *val;
}

static void update_packet_rate(__u32 ip)
{
    __u64 now = bpf_ktime_get_ns();
    __u64 *val = bpf_map_lookup_elem(&src_ip_map, &ip);

    if (!val) {
        __u64 new_val = now;
        bpf_map_update_elem(&src_ip_map, &ip, &new_val, BPF_ANY);
    } else {
        __u64 last = *val;
        // 简单计数（实际需要滑动窗口）
        __u64 new_val = last + 1;
        bpf_map_update_elem(&src_ip_map, &ip, &new_val, BPF_ANY);
    }
}

SEC("xdp")
int xdp_ddos_filter(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    __u32 src_ip = iph->saddr;

    // 检查源 IP 速率
    __u64 rate = get_packet_rate(src_ip);
    if (rate > RATE_LIMIT) {
        // 超限，丢弃
        return XDP_DROP;
    }

    // 更新速率
    update_packet_rate(src_ip);

    // SYN flood 检测（TCP）
    if (iph->protocol == IPPROTO_TCP) {
        struct tcphdr *tcph = data + sizeof(*eth) + sizeof(*iph);
        if ((void *)(tcph + 1) > data_end)
            return XDP_PASS;

        // SYN flood：SYN=1, ACK=0
        if (tcph->syn && !tcph->ack) {
            // 简单 SYN count
            // 实际需要 per-src-ip SYN 计数
        }
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

### 7.2 包镜像与分流

```c
// xdp_mirror.c — 包镜像与分流

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <bpf/bpf_helpers.h>

// 镜像目标设备 Map
struct {
    __uint(type, BPF_MAP_TYPE_DEVMAP);
    __uint(max_entries, 8);
    __type(key, __u32);  // ifindex
    __type(value, struct bpf_devmap_val);
} mirror_devmap SEC(".maps");

// 镜像端口（抓包分析）
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 2);
    __type(key, __u32);
    __type(value, __u32);  // ifindex
} mirror_ports SEC(".maps");

SEC("xdp")
int xdp_mirror(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // 获取目标端口（简化：固定端口镜像）
    __u32 port_key = 0;
    __u32 *mirror_ifindex = bpf_map_lookup_elem(&mirror_ports, &port_key);
    if (!mirror_ifindex)
        return XDP_PASS;

    // 原始包继续处理
    // ...

    // 镜像到抓包口（需要克隆包）
    // XDP TX 目前不支持克隆，需要使用 cpumap 或 xdp_redirect_map
    // 这里使用 device map 转发
    // return bpf_redirect_map(&mirror_devmap, *mirror_ifindex, 0);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

---

## 8. 调试与排错

### 8.1 常见错误

```
XDP/BPF 常见错误：

┌────────────────────────────────────────────────────────────────┐
│  错误                          │  原因 / 解决                   │
├────────────────────────────────────────────────────────────────┤
│  "too many map accesses"       │  超出辅助函数调用限制         │
│  "tail_call out of bounds"     │  index 超出 prog_array size   │
│  "failed to find logic Core"  │  CO-RE 找不到类型定义         │
│  "invalid stack access"       │  栈越界，未检查边界           │
│  "cannot call function"       │  BPF 不支持该函数调用         │
│  "permission denied"           │  需要 root 或 CAP_BPF         │
│  "cannot open .o: no such"    │  文件路径或内核架构不匹配     │
│  "Unknown symbol"             │  辅助函数不存在该内核版本     │
└────────────────────────────────────────────────────────────────┘

调试方法：

  1. bpf_trace_printk（输出到 trace_pipe）
     bpf_trace_printk("debug: %d\n", value);

  2. 查看验证日志
     # dmesg | tail -50

  3. 查看 ring buffer
     # cat /sys/kernel/debug/tracing/trace_pipe

  4. bpftool 查看加载的程序
     # bpftool prog show
     # bpftool map show

  5. 查看 XDP 统计
     # ip link show
     # ethtool -S eth0 | grep xdp
```

### 8.2 调试脚本

```bash
#!/bin/bash
# debug_xdp.sh — XDP 调试脚本

IFACE="${1:-eth0}"

echo "=== XDP 调试信息 ==="

# 1. 查看网卡 XDP 状态
echo ""
echo "[1] 网卡 XDP 状态:"
ip link show $IFACE

# 2. 查看已加载程序
echo ""
echo "[2] 已加载 BPF 程序:"
bpftool prog show | grep -A5 xdp || echo "无 XDP 程序"

# 3. 查看 Maps
echo ""
echo "[3] BPF Maps:"
bpftool map show

# 4. 读取 Map 内容（示例）
echo ""
echo "[4] 读取 stats_map:"
# bpftool map dump id <map_id>

# 5. 查看 trace buffer
echo ""
echo "[5] trace_pipe (5秒):"
timeout 5 cat /sys/kernel/debug/tracing/trace_pipe 2>/dev/null || echo "无 trace"

# 6. dmesg 日志
echo ""
echo "[6] 内核日志 (dmesg | tail -20):"
dmesg | tail -20 | grep -i "xdp\|bpf" || echo "无相关日志"

# 7. 查看统计
echo ""
echo "[7] 网卡统计:"
ethtool -S $IFACE | grep -i "xdp\|drop" || echo "无可用统计"
```

### 8.3 验证程序

```bash
#!/bin/bash
# verify_xdp.sh — XDP 程序验证

PROG="${1:-xdp_basic.o}"
IFACE="${2:-eth0}"

echo "=== XDP 程序验证 ==="

# 1. 确认编译成功
echo "[1] 检查目标文件:"
file $PROG
llvm-objdump -h $PROG | grep -E "xdp|license"

# 2. 检查 section
echo ""
echo "[2] XDP Sections:"
llvm-readelf -S $PROG | grep -E "xdp|\.license"

# 3. 反汇编（验证 JIT）
echo ""
echo "[3] 反汇编:"
llvm-objdump -d $PROG 2>/dev/null | head -40

# 4. 加载前测试（dry run）
echo ""
echo "[4] 尝试加载..."
ip link set dev $IFACE xdp obj $PROG sec xdp 2>&1 && echo "成功！" || echo "失败"

# 5. 确认运行
echo ""
echo "[5] 运行状态:"
ip link show $IFACE | grep -E "xdp|eth"
```

---

## 9. 小结

```
XDP 脚本与 BPF 程序总结：

开发环境：
  · 依赖：clang, llvm, libbpf, linux-headers, bpftool
  · 内核：4.18+（完整特性）
  · 驱动：ice, mlx5（最佳支持）

BPF 程序结构：
  · SEC("xdp") — XDP 程序入口
  · 返回值：XDP_PASS/DROP/REDIRECT/TX
  · 必须：char _license[] SEC("license") = "GPL"

Map 类型：
  · HASH — IP 黑名单/统计
  · ARRAY — 计数器（O(1)）
  · DEVMAP — 重定向到网卡
  · PROG_ARRAY — Tail Call
  · LRU_HASH — 连接跟踪

Tail Call：
  · bpf_tail_call(ctx, &prog_array, index)
  · 最多 32 层嵌套
  · 模块化：入口 → 分发 → 具体处理

libbpf 骨架：
  · bpftool gen skeleton → *.skel.h
  · xdp_bpf__open_and_load()
  · xpf_bpf__attach()

CO-RE：
  · BPF_CORE_READ 代替直接访问
  · 跨内核版本兼容
  · 自动重定位 struct 字段偏移

典型应用：
  · DDoS 防御（速率限制/SYN flood）
  · 负载均衡（DEVMAP 重定向）
  · 包镜像（cpumap/trace）
  · 防火墙（IP/Port 过滤）

调试：
  · bpf_trace_printk → trace_pipe
  · dmesg | tail
  · bpftool prog/map show
  · ethtool -S eth0 | grep xdp

系列预告：
  Ch3: AF_XDP 数据路径分析
  Ch4: AF_XDP vs DPDK vs io_uring 对比
  Ch5: AF_XDP + io_uring 融合架构
  Ch6: 生产环境实战与调优
```

---

## 延伸阅读

- BPF 官方文档: `Documentation/bpf/bpf_devel_QA.rst`
- XDP 文档: `Documentation/networking/xdp.rst`
- libbpf: `https://github.com/libbpf/libbpf`
- BCC: `https://github.com/iovisor/bcc`
- XDP 最佳实践: `https://www.kernel.org/doc/html/latest/networking/xdp-implementation.html`
- BPF CO-RE: `https://nakryiko.com/posts/bpf-core-reference-guide/`
- Andrii Nakryiko 的博客: `https://nakryiko.com/`
- Facebook XDP 案例: `https://facebookmicrosites.github.io/bpf/blog/`
- Cloudflare XDP DDoS: `https://blog.cloudflare.com/tag/xdp/`
