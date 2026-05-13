---
title: "Kernel Protocol Stack 深度探索 (三十八)：XDP 与高性能网络处理"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    xdp,
    af-xdp,
    zero-copy,
    ebpf,
    xdp-redirect,
    dpdk-xdp,
    ddos-mitigation,
    netfilter-xdp,
  ]
description: "深入解析 XDP（eXpress Data Path）——XDP 在协议栈中的位置、程序类型、XDP action、XDP redirect/tx/pass、AF_XDP 零拷贝、与 Netfilter 的协同与对比、以及 DDoS 防护、负载均衡的典型应用"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 33. [[2026-04-13-kernel-protocol-stack-deep-dive-ch33-netfilter-hook|第三十三章：Netfilter 框架详解]] 37. [[2026-04-13-kernel-protocol-stack-deep-dive-ch38-nat-deep|第三十七章：NAT 深度解析]] 38. **第三十八章：XDP 与高性能网络处理**

---

## 1. XDP 概述

XDP（eXpress Data Path）是 Linux 内核 4.8（2016）引入的高性能可编程包处理框架。它允许 eBPF 程序在**网卡驱动层**（或网卡硬件上）直接处理数据包，在进入 Linux 网络协议栈之前就完成过滤、转发、修改等操作。

### 1.1 XDP 在协议栈中的位置

```
硬件收包
    │
    ▼
网卡驱动 RX 队列
    │
    ├──► [XDP hook] ← eBPF 程序在此执行
    │        │
    │        ├─ XDP_DROP    → 直接丢弃（DRV 层，最快）
    │        ├─ XDP_PASS    → 继续走协议栈
    │        ├─ XDP_TX      → 从同一网卡发回
    │        ├─ XDP_REDIRECT → 重定向到另一网卡/CPU/AF_XDP socket
    │        └─ XDP_ABORTED → 错误丢弃（记录事件）
    │
    ▼
GRO / RPS
    │
    ▼
tc ingress (cls_bpf)
    │
    ▼
Netfilter: NF_INET_PRE_ROUTING
    │
    ▼
IP routing...
```

### 1.2 三种 XDP 运行模式

| 模式            | 说明                                 | 性能               | 驱动要求         |
| --------------- | ------------------------------------ | ------------------ | ---------------- |
| **Native XDP**  | 在驱动 RX 轮询中执行（NAPI poll 内） | 最高 (14+ Mpps)    | 需驱动支持       |
| **Offload XDP** | 在智能网卡 NPU 上执行                | 极高（卸载到硬件） | 需 SmartNIC 支持 |
| **Generic XDP** | 在 GRO 后协议栈软件层执行            | 较低 (~3 Mpps)     | 任意网卡         |

```bash
# 加载 XDP 程序
# Native 模式（推荐）
ip link set dev eth0 xdp obj xdp_prog.o sec xdp

# Offload 模式
ip link set dev eth0 xdpoffload obj xdp_prog.o sec xdp

# Generic 模式
ip link set dev eth0 xdpgeneric obj xdp_prog.o sec xdp

# 卸载 XDP 程序
ip link set dev eth0 xdp off
```

---

## 2. XDP 程序结构

### 2.1 最简 XDP 程序

```c
// xdp_drop_all.c
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <arpa/inet.h>

SEC("xdp")
int xdp_drop_all(struct xdp_md *ctx)
{
    // xdp_md 提供对包数据的访问
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 边界检查（BPF verifier 强制要求）
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    // 只处理 IPv4
    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    // 丢弃来自特定 IP 的包
    if (ip->saddr == htonl(0x01020304))  // 1.2.3.4
        return XDP_DROP;

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

### 2.2 xdp_md 结构

```c
// include/uapi/linux/bpf.h
struct xdp_md {
    __u32 data;           // 包数据起始地址（相对偏移）
    __u32 data_end;       // 包数据结束地址
    __u32 data_meta;      // 元数据区域（XDP_PASS 后传递给 TC eBPF）
    __u32 ingress_ifindex; // 入接口 index
    __u32 rx_queue_index;  // RX 队列号
    __u32 egress_ifindex;  // 出接口（仅 XDP_REDIRECT 后）
};
```

---

## 3. XDP Maps：状态共享

XDP 程序通过 BPF Maps 与内核/用户空间共享状态：

### 3.1 黑名单过滤（Array/Hash Map）

```c
// 使用 BPF hash map 存储黑名单
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);       // IPv4 地址
    __type(value, __u64);     // 丢包计数
    __uint(max_entries, 65536);
} blacklist SEC(".maps");

SEC("xdp")
int xdp_blacklist(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;
    if (eth->h_proto != htons(ETH_P_IP)) return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end) return XDP_PASS;

    __u64 *count = bpf_map_lookup_elem(&blacklist, &ip->saddr);
    if (count) {
        __sync_fetch_and_add(count, 1);
        return XDP_DROP;
    }
    return XDP_PASS;
}
```

### 3.2 用户空间动态更新黑名单

```c
// 用户态程序（libbpf）
int main()
{
    struct bpf_object *obj = bpf_object__open("xdp_blacklist.o");
    bpf_object__load(obj);

    // 获取 map fd
    int map_fd = bpf_object__find_map_fd_by_name(obj, "blacklist");

    // 添加黑名单 IP
    __u32 bad_ip = inet_addr("1.2.3.4");
    __u64 count = 0;
    bpf_map_update_elem(map_fd, &bad_ip, &count, BPF_ANY);

    // 附加 XDP 程序到接口
    int prog_fd = bpf_program__fd(bpf_object__find_program_by_name(obj, "xdp_blacklist"));
    bpf_xdp_attach(ifindex, prog_fd, 0, NULL);

    // 监控丢包
    while (1) {
        bpf_map_lookup_elem(map_fd, &bad_ip, &count);
        printf("Dropped %llu packets from 1.2.3.4\n", count);
        sleep(1);
    }
}
```

---

## 4. XDP_REDIRECT：高性能转发

### 4.1 重定向到另一个网卡（包转发）

```c
// XDP 直接将包从 eth0 转发到 eth1（绕过内核网络栈）
struct {
    __uint(type, BPF_MAP_TYPE_DEVMAP);
    __type(key, __u32);    // 目标接口 index
    __type(value, __u32);  // 接口 index
    __uint(max_entries, 256);
} tx_port SEC(".maps");

SEC("xdp")
int xdp_redirect_map(struct xdp_md *ctx)
{
    __u32 key = 0;
    // 查找出口接口
    return bpf_redirect_map(&tx_port, key, XDP_PASS);
}
```

### 4.2 XDP CPU Redirect（多核负载均衡）

```c
// 将包重定向到特定 CPU 队列处理（可实现 RSS 替代）
struct {
    __uint(type, BPF_MAP_TYPE_CPUMAP);
    __type(key, __u32);   // CPU ID
    __type(value, struct bpf_cpumap_val);
    __uint(max_entries, 12);
} cpumap SEC(".maps");

SEC("xdp")
int xdp_cpu_redirect(struct xdp_md *ctx)
{
    __u32 cpu = bpf_get_smp_processor_id();
    __u32 target_cpu = cpu % 4;  // 分发到前 4 个 CPU
    return bpf_redirect_map(&cpumap, target_cpu, 0);
}
```

---

## 5. AF_XDP：零拷贝用户态处理

AF_XDP 是 XDP_REDIRECT 的终点之一，允许将数据包**零拷贝**地传递到用户空间：

### 5.1 架构

```
RX 队列（共享内存 UMEM）
    │
    ├── Fill Queue (FQ)：用户态提供空闲缓冲区 ──────────────────────┐
    │                                                               │
    ├── RX Queue：内核填充收到的包 ──► 用户空间程序读取、处理包      │
    │                                                               │
    ├── TX Queue：用户空间提交待发送的包                             │
    │                                                               │
    └── Completion Queue (CQ)：发送完成通知 ◄────────────────────────┘

关键：所有队列操作直接在共享内存上进行，无需系统调用（除初始化外）
```

### 5.2 配置示例（libbpf）

```c
// AF_XDP socket 创建
struct xsk_socket_config cfg = {
    .rx_size = 4096,
    .tx_size = 4096,
    .libbpf_flags = 0,
    .xdp_flags = XDP_FLAGS_DRV_MODE,   // Native XDP
    .bind_flags = XDP_ZEROCOPY,         // 零拷贝模式
};

struct xsk_umem *umem;
struct xsk_socket *xsk;

// 分配 UMEM（共享内存区域）
void *bufs = mmap(NULL, NUM_FRAMES * FRAME_SIZE,
                  PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);

xsk_umem__create(&umem, bufs, NUM_FRAMES * FRAME_SIZE,
                 &fq, &cq, NULL);

// 创建 AF_XDP socket
xsk_socket__create(&xsk, "eth0", queue_id, umem, &rx, &tx, &cfg);

// 接收包（轮询模式）
while (1) {
    uint32_t idx_rx;
    unsigned int rcvd = xsk_ring_cons__peek(&rx, BATCH_SIZE, &idx_rx);
    for (unsigned int i = 0; i < rcvd; i++) {
        uint64_t addr = xsk_ring_cons__rx_desc(&rx, idx_rx + i)->addr;
        uint32_t len  = xsk_ring_cons__rx_desc(&rx, idx_rx + i)->len;
        void *pkt = xsk_umem__get_data(bufs, addr);
        process_packet(pkt, len);
    }
    xsk_ring_cons__release(&rx, rcvd);
}
```

### 5.3 性能对比

| 方案                  | 吞吐量    | 延迟   | 用户态访问           |
| --------------------- | --------- | ------ | -------------------- |
| 传统 socket (recvmsg) | ~1 Mpps   | ~5us   | 有拷贝               |
| DPDK (UIO/VFIO)       | ~20+ Mpps | ~200ns | 零拷贝，完全绕过内核 |
| AF_XDP (copy mode)    | ~5 Mpps   | ~1us   | 有拷贝               |
| AF_XDP (zerocopy)     | ~14 Mpps  | ~300ns | 零拷贝，仍走内核调度 |

---

## 6. XDP 与 Netfilter 的协同

XDP 和 Netfilter 不是竞争关系，而是互补的：

### 6.1 分层防御策略

```
流量分层处理：

1. XDP 层（网卡驱动，极早期）：
   - 已知攻击 IP 黑名单（BPF hash map）
   - SYN Flood 速率限制（BPF hash + 令牌桶）
   - 协议格式异常（畸形包）检测
   → 处理：XDP_DROP（无需进入内核协议栈，最低开销）

2. TC/Netfilter 层（协议栈内）：
   - 有状态防火墙（conntrack）
   - NAT（需要连接状态）
   - 复杂规则（layer7、应用识别）
   - 日志记录
   → 处理：iptables/nftables 规则

原则：XDP 处理"简单高频"流量，Netfilter 处理"复杂低频"流量
```

### 6.2 XDP 元数据传递给 Netfilter

```c
// XDP 程序写入 meta 区域（位于 data 前面）
struct xdp_meta {
    __u32 mark;
    __u32 rx_hash;
};

SEC("xdp")
int xdp_mark_packet(struct xdp_md *ctx)
{
    // 调整 meta 区域（向前扩展 sizeof(struct xdp_meta) 字节）
    if (bpf_xdp_adjust_meta(ctx, -(int)sizeof(struct xdp_meta)) != 0)
        return XDP_PASS;

    void *meta     = (void *)(long)ctx->data_meta;
    void *data     = (void *)(long)ctx->data;

    struct xdp_meta *m = meta;
    if ((void *)(m + 1) > data)
        return XDP_PASS;

    m->mark = 0x100;  // 设置包标记

    return XDP_PASS;  // 传递给 TC，TC 读取 meta
}

// TC eBPF 程序读取 XDP 传递的 meta，设置 skb->mark
// 然后 iptables 基于 skb->mark 匹配
```

---

## 7. 实战：XDP DDoS 防护

### 7.1 SYN Flood 防护

```c
// SYN Cookie 验证（XDP 实现）
struct {
    __uint(type, BPF_MAP_TYPE_LRU_PERCPU_HASH);
    __type(key, __u32);    // 源 IP
    __type(value, struct rate_info);
    __uint(max_entries, 100000);
} syn_rate_map SEC(".maps");

struct rate_info {
    __u64 last_ts;
    __u32 count;
};

SEC("xdp")
int xdp_syn_limit(struct xdp_md *ctx)
{
    // 解析以太网/IP/TCP 头...
    if (tcp->syn && !tcp->ack) {
        __u32 src_ip = ip->saddr;
        __u64 now = bpf_ktime_get_ns();

        struct rate_info *ri = bpf_map_lookup_elem(&syn_rate_map, &src_ip);
        if (!ri) {
            struct rate_info new_ri = { .last_ts = now, .count = 1 };
            bpf_map_update_elem(&syn_rate_map, &src_ip, &new_ri, BPF_ANY);
            return XDP_PASS;
        }

        // 1秒内超过 100 个 SYN
        if (now - ri->last_ts < 1000000000ULL) {
            if (ri->count >= 100)
                return XDP_DROP;
            ri->count++;
        } else {
            ri->last_ts = now;
            ri->count = 1;
        }
    }
    return XDP_PASS;
}
```

### 7.2 UDP Amplification 防护

```c
// 阻断 DNS/NTP/SSDP 放大攻击
SEC("xdp")
int xdp_block_amplification(struct xdp_md *ctx)
{
    // 解析 UDP...
    if (ip->protocol == IPPROTO_UDP) {
        __u16 sport = bpf_ntohs(udp->source);
        // 阻断常见放大攻击源端口
        if (sport == 53   ||  // DNS
            sport == 123  ||  // NTP
            sport == 1900 ||  // SSDP
            sport == 11211)   // Memcached
        {
            // 检查包大小（放大攻击通常包很大）
            __u32 pkt_len = data_end - data;
            if (pkt_len > 512)
                return XDP_DROP;
        }
    }
    return XDP_PASS;
}
```

---

## 8. XDP 负载均衡（Katran 架构）

Facebook 的 Katran 是基于 XDP 的 L4 负载均衡器，在 ~8 Mpps 速率下延迟 < 100us：

```
客户端 → VIP:80 → XDP LB 程序
    │
    ├── 查找一致性哈希环（BPF map）
    ├── 查找后端服务器地址
    ├── 封装成 GUE/IPIP 隧道
    └── XDP_TX / XDP_REDIRECT → 后端服务器

后端服务器通过 GUE 解封装直接回复给客户端（DSR 模式，LB 不处理回包）
```

---

## 9. 调试与性能分析

```bash
# 查看 XDP 程序加载状态
ip link show dev eth0       # 显示 xdp 字段
bpftool net show dev eth0   # 详细信息

# 查看 BPF 程序信息
bpftool prog show
bpftool prog dump xlated id <prog_id>  # 反汇编
bpftool prog dump jited id <prog_id>   # JIT 机器码

# XDP 统计（通过 ethtool）
ethtool -S eth0 | grep -i xdp

# 使用 perf 分析 XDP 程序热点
perf stat -e xdp:xdp_exception -- sleep 10
perf record -e xdp:* -- sleep 5
perf script | head -50

# bpftrace 追踪 XDP 丢包
bpftrace -e 'tracepoint:xdp:xdp_exception { @[args->ifindex, args->act] = count(); }'
```

---

## 10. 小结

XDP 是 Linux 内核网络处理的高性能快速路径：

- **Native XDP** 在驱动 NAPI poll 中执行，延迟仅 ~70ns/包
- **XDP_DROP** 是最快的丢包路径（DDoS 防护利器），无需进入协议栈
- **XDP_REDIRECT** 实现包的零拷贝转发（网卡直转/CPU 分发/AF_XDP 用户态）
- **AF_XDP** 提供类 DPDK 的零拷贝用户态处理，但仍保留内核管理
- **与 Netfilter 协同**：XDP 处理简单高频流量，Netfilter 处理复杂有状态流量
- **meta 机制**使 XDP 能向 TC/Netfilter 传递预处理信息

下一章将介绍 **Linux QoS 框架**——tc（Traffic Control）的队列规则（qdisc）、分类器、token bucket filter、HTB/HFSC 带宽整形，以及 Kubernetes 网络 QoS 的内核实现。
