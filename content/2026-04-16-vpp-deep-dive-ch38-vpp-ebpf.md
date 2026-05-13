---
title: "VPP 深入探讨 ch38：VPP + eBPF 协同"
date: 2026-04-16 11:10:00
tags: [vpp, ebpf, xdp, tc, af-xdp, offload, kernel-bypass, datapath]
description: "深入解析 VPP 与 eBPF 协同工作：XDP 集成、TC 流量控制、AF-XDP 零拷贝、eBPF 卸载、以及混合数据平面架构"
---

# VPP 深入探讨 ch38：VPP + eBPF 协同

> [!abstract] 核心要点
> eBPF 和 VPP 是互补的数据平面技术。本章详解两者协同架构：XDP 作为 VPP 的前端过滤器、TC 流量控制、AF-XDP 零拷贝路径、以及 eBPF 辅助 VPP 卸载的混合部署模式。

## 1. eBPF 与 VPP 概述

### 1.1 技术定位对比

```
┌─────────────────────────────────────────────────────────────┐
│                    eBPF vs VPP 定位                         │
│                                                              │
│  eBPF:                                                       │
│  - 内核态可编程                                               │
│  - 安全沙箱                                                  │
│  - 快速内核路径                                              │
│  - 钩子丰富 (XDP, TC, kprobe, etc.)                          │
│                                                              │
│  VPP:                                                        │
│  - 用户态数据平面                                            │
│  - 图节点架构                                                │
│  - 高吞吐 (~10M PPS)                                        │
│  - 成熟协议栈                                                │
│                                                              │
│  协同:                                                       │
│  eBPF ──► 过滤/采样 ──► VPP ──► 复杂处理                    │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 互补性分析

|| 特性 | eBPF | VPP |
|------|------|-----|
| **运行位置** | 内核态 | 用户态 |
| **延迟** | 极低 (<1μs) | 低 (~10μs) |
| **吞吐** | 极高 | 极高 |
| **协议栈** | 有限 | 完整 (L2-L7) |
| **可编程性** | 有限 (辅助函数) | 灵活 (C/Go) |
| **生态** | 工具丰富 | 协议丰富 |

### 1.3 协同场景

```
┌─────────────────────────────────────────────────────────────┐
│                    eBPF + VPP 协同场景                      │
│                                                              │
│  1. 流量过滤前端                                             │
│     eBPF ──► 快速过滤 ──► VPP ──► 深度检测                   │
│                                                              │
│  2. 镜像/采样                                                │
│     eBPF ──► 包镜像 ──► VPP ──► 存储分析                    │
│                                                              │
│  3. 加速路径                                                 │
│     eBPF ──► 绕过内核 ──► VPP ──► 快速转发                   │
│                                                              │
│  4. 可见性                                                   │
│     eBPF ──► Telemetry ──► VPP ──► 监控                    │
└─────────────────────────────────────────────────────────────┘
```

## 2. XDP 集成架构

### 2.1 XDP 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                    XDP 处理流程                             │
│                                                              │
│  NIC 接收包                                                  │
│       │                                                      │
│       ▼                                                      │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              XDP 程序 (eBPF)                          │   │
│  │                                                       │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │   │
│  │  │ XDP_DROP │  │XDP_PASS │  │XDP_REDIRECT│           │   │
│  │  └─────────┘  └─────────┘  └─────────┘            │   │
│  └─────────────────────────────────────────────────────┘   │
│       │            │            │                            │
│       ▼            ▼            ▼                            │
│    丢弃         正常流程      转发到其他口                    │
│                                                              │
│  位置: 网卡驱动层 (before skb allocation)                   │
│  优势: 最早期处理，极低延迟                                   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 XDP + VPP 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    XDP + VPP 架构                           │
│                                                              │
│  NIC                                                         │
│    │                                                        │
│    ▼                                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              XDP (eBPF)                              │   │
│  │                                                       │   │
│  │  - 快速过滤 (DDoS 防护)                               │   │
│  │  - 采样 (NetFlow/sFlow)                              │   │
│  │  - 统计收集                                          │   │
│  │  - XDP_REDIRECT ──► AF_XDP Socket                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              AF_XDP Socket                          │   │
│  │              (Zero-Copy Path)                        │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              VPP (用户态数据平面)                     │   │
│  │                                                       │   │
│  │  - 完整协议栈                                        │   │
│  │  - NAT/Firewall/QoS                                 │   │
│  │  - Tunnel 封装/解封装                                │   │
│  │  - 路由查找                                          │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 XDP 程序示例

```c
// xdp_vpp_firewall.bpf.c

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include "common.h"

/* 全局映射: 允许的 IP 列表 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);      // IP 地址
    __type(value, __u8);     // 允许标志
} allowed_ips SEC(".maps");

/* 统计映射 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 256);
    __type(key, __u32);      // 协议类型
    __type(value, __u64);     // 计数
} packet_stats SEC(".maps");

SEC("xdp")
int xdp_vpp_filter(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;
    
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;
    
    /* 只处理 IPv4 */
    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;
    
    struct iphdr *ip = data + sizeof(*eth);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;
    
    __u32 src_ip = ip->saddr;
    
    /* 检查是否在允许列表 */
    __u8 *allowed = bpf_map_lookup_elem(&allowed_ips, &src_ip);
    if (allowed && *allowed == 1) {
        /* 允许的流量: 重定向到 VPP */
        return XDP_REDIRECT;
    }
    
    /* DDoS 防护: 速率限制 */
    if (bpf_map_lookup_elem(&packet_stats, &ip->protocol)) {
        return XDP_DROP;
    }
    
    /* 默认: 传给内核网络栈 */
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

## 3. TC (Traffic Control) 集成

### 3.1 TC eBPF 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    TC eBPF 架构                             │
│                                                              │
│  包进入                                                      │
│    │                                                        │
│    ▼                                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              TC Ingress (PREROUTING)                 │   │
│  │                                                       │   │
│  │  - 分类/标记                                          │   │
│  │  - 防火墙标记                                        │   │
│  │  - 负载均衡                                          │   │
│  │  - 可能的 eBPF 动作                                  │   │
│  └─────────────────────────────────────────────────────┘   │
│    │                                                        │
│    │                                                        │
│    ▼                                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              路由决策                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│    │                                                        │
│    ▼                                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              TC Egress (POSTROUTING)                │   │
│  │                                                       │   │
│  │  - 流量整形                                          │   │
│  │  - QoS 标记                                          │   │
│  │  - 调度                                              │   │
│  └─────────────────────────────────────────────────────┘   │
│    │                                                        │
│    ▼                                                        │
│  NIC                                                         │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 TC + VPP 流量标记

```bash
# 1. 创建 TC eBPF 程序
cat > tc_vpp_mark.bpf.c << 'EOF'
#include <linux/bpf.h>
#include <linux/pkt_cls.h>
#include <linux/if_ether.h>
#include <linux/ip.h>

SEC("clsact")
int tc_mark(struct __sk_buff *skb)
{
    __u8 *cursor = 0;
    struct ethhdr *eth = bpf_hdr_pointer(skb, ETH_HLEN, sizeof(*eth));
    
    if (!eth || eth->h_proto != htons(ETH_P_IP))
        return TC_ACT_OK;
    
    struct iphdr *ip = (struct iphdr *)(eth + 1);
    __u32 dst = ip->daddr;
    
    /* 标记流量用于 VPP 处理 */
    bpf_skb_store_bytes(skb, offsetof(struct iphdr, protocol), 
                        &ip->protocol, sizeof(__u8), 0);
    
    /* 设置 mark 用于后续分类 */
    bpf_skb_mark(skb, 0x1234);
    
    return TC_ACT_OK;
}
EOF

# 2. 附加到接口
tc qdisc add dev eth0 clsact
tc filter add dev eth0 ingress bpf obj tc_vpp_mark.bpf.o sec clsact

# 3. VPP 读取 mark 并分类
vpp# set interface input acl TenGigabitEthernet0/0/0 ip table 100 mark 0x1234
```

### 3.3 VPP TC 协同配置

```bash
# VPP 中使用 tc 分类的流量
vpp# show ip tables

# 配置基于 fwmark 的路由
vpp# ip table add 100
vpp# ip route add 0.0.0.0/0 via 10.0.0.1 table 100

# 配置基于 mark 的策略路由
vpp# classify table action dpo-lookup ip6 fib table 100
vpp# set ip table 100
```

## 4. AF-XDP 零拷贝路径

### 4.1 AF-XDP 原理

```
┌─────────────────────────────────────────────────────────────┐
│                    AF_XDP 零拷贝路径                        │
│                                                              │
│  传统路径:                                                    │
│  NIC ──► DMA ──► skb ──► 拷贝 ──► 应用                      │
│                                                              │
│  AF_XDP 路径:                                                │
│  NIC ──► DMA ──► UMEM ──► 应用 (零拷贝)                     │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    UMEM (Memory Region)              │   │
│  │                                                       │   │
│  │  ┌───────────────────────────────────────────────┐   │   │
│  │  │  Frame 0 │ Frame 1 │ Frame 2 │ Frame 3 │ ... │   │   │
│  │  └───────────────────────────────────────────────┘   │   │
│  │                                                       │   │
│  │  FILL RING (NIC 填充)                                │   │
│  │  COMPLETION RING (消费完成)                          │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 AF-XDP + VPP 配置

```bash
# 1. 检查 NIC 支持
ethtool -k eth0 | grep xdp

# 2. 创建 AF_XDP Socket
cat > create_af_xdp.c << 'EOF'
#include <linux/if_xdp.h>
#include <sys/socket.h>
#include <net/if.h>

int create_af_xdp_socket(const char *ifname, int queue_id)
{
    int sock, fd;
    struct sockaddr_xdp addr;
    
    /* 创建 XSK socket */
    sock = socket(AF_XDP, SOCK_RAW, 0);
    
    /* 设置 UMEM */
    struct xdp_mmap_offsets off;
    socklen_t len = sizeof(off);
    getsockopt(sock, SOL_XDP, XDP_MMAP_OFFSETS, &off, &len);
    
    /* 绑定到接口和队列 */
    memset(&addr, 0, sizeof(addr));
    addr.sxdp_family = AF_XDP;
    addr.sxdp_ifindex = if_nametoindex(ifname);
    addr.sxdp_queue_id = queue_id;
    
    bind(sock, (struct sockaddr *)&addr, sizeof(addr));
    
    return sock;
}
EOF

# 3. VPP 启用 AF_XDP 接口
vpp# create interface af-xdp name eth0 queue-size 1024
vpp# set interface state af-xdp-0 up
```

### 4.3 性能对比

|| 路径 | 延迟 | 吞吐 | CPU 使用 |
|------|------|------|---------|
| **内核协议栈** | ~100μs | 1 Gbps | 高 |
| **DPDK** | ~5μs | 10 Gbps | 中 |
| **XDP_PASS** | ~10μs | 8 Gbps | 中 |
| **AF_XDP** | ~3μs | 10 Gbps | 低 |
| **VPP (AF_XDP)** | ~5μs | 15 Gbps | 低 |

## 5. eBPF 辅助 VPP 卸载

### 5.1 卸载场景

```
┌─────────────────────────────────────────────────────────────┐
│                    eBPF 辅助卸载场景                        │
│                                                              │
│  1. 统计收集 (XDP)                                           │
│     - 包计数/字节计数                                        │
│     - 协议分布                                               │
│     - 异常检测                                               │
│                                                              │
│  2. 流分类 (TC)                                              │
│     - 5-tuple 流识别                                         │
│     - DSCP 标记                                              │
│     - 策略路由                                               │
│                                                              │
│  3. 加密卸载 (ICL)                                           │
│     - IPSec SPI 分类                                        │
│     - 密钥查找                                              │
│                                                              │
│  4. NAT 辅助 (CT)                                            │
│     - 连接跟踪                                              │
│     - 包标记                                                │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 连接跟踪卸载

```c
// ebpf_conntrack.bpf.c - eBPF 连接跟踪辅助

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>

/* 连接跟踪映射 */
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 100000);
    __type(key, struct tuple);
    __type(value, struct conntrack_entry);
} ct_map SEC(".maps");

/* 元组结构 */
struct tuple {
    __u32 src_ip;
    __u32 dst_ip;
    __u16 src_port;
    __u16 dst_port;
    __u8 protocol;
};

/* 连接状态 */
struct conntrack_entry {
    __u32 status;           // ESTABLISHED, NEW, RELATED
    __u64 packets;
    __u64 bytes;
    __u64 last_seen;
    __u32 orig_dir;         // 原始方向
    __u32 reply_dir;        // 回复方向
};

/* XDP 连接跟踪程序 */
SEC("xdp")
int xdp_conntrack(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth = data;
    struct iphdr *ip = (struct iphdr *)(eth + 1);
    struct tcphdr *tcp = (struct tcphdr *)(ip + 1);
    
    struct tuple key = {
        .src_ip = ip->saddr,
        .dst_ip = ip->daddr,
        .src_port = tcp->source,
        .dst_port = tcp->dest,
        .protocol = ip->protocol
    };
    
    /* 查找连接 */
    struct conntrack_entry *ct = bpf_map_lookup_elem(&ct_map, &key);
    if (ct) {
        ct->packets++;
        ct->bytes += ctx->data_end - ctx->data;
        ct->last_seen = bpf_ktime_get_ns();
        
        /* 已建立的连接: 快速路径 */
        if (ct->status == ESTABLISHED) {
            return XDP_REDIRECT;
        }
    }
    
    /* 新连接: 传给 VPP 处理 */
    return XDP_PASS;
}
```

### 5.3 VPP 读取 eBPF 映射

```bash
# VPP 配置读取 eBPF 映射的连接跟踪
vpp# ebpf attach xdp-counters ct_map

# 显示 eBPF 统计
vpp# show ebpf counters

# 示例输出:
# eBPF Counters:
#   ct_map entries: 50000
#   packets: 1000000000
#   bytes: 500000000000
#   Established: 49000
#   New: 1000
```

## 6. 混合数据平面架构

### 6.1 设计原则

```
混合部署策略：

┌─────────────────────────────────────────────────────────────┐
│                    混合数据平面架构                          │
│                                                              │
│  边缘节点 (Edge):                                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  eBPF (XDP/TC) ──► VPP ──► NIC                     │   │
│  │                                                       │   │
│  │  优势: 极低延迟 + 完整协议栈                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  核心节点 (Core):                                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  NIC ──► VPP ──► eBPF (monitor)                     │   │
│  │                                                       │   │
│  │  优势: 高吞吐 + 深度可见性                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  安全节点 (Security):                                       │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  eBPF (filter) ──► VPP (DPI) ──► eBPF (crypt)      │   │
│  │                                                       │   │
│  │  优势: 快速过滤 + 深度检测 + 加密                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 部署配置

```bash
# 混合部署示例

# 1. XDP 前端过滤
ip link set dev eth0 xdp obj xdp_firewall.bpf.o sec xdp

# 2. VPP 中间处理
vpp# set interface ip address TenGigabitEthernet0/0/0 10.0.0.1/24
vpp# set interface ip address TenGigabitEthernet0/0/1 10.0.1.1/24
vpp# set interface state TenGigabitEthernet0/0/0 up
vpp# set interface state TenGigabitEthernet0/0/1 up

# 3. ACL 规则
vpp# acl add rule 100 permit ip src 10.0.0.0/8 dst 10.0.0.0/8
vpp# acl interface TenGigabitEthernet0/0/0 inputacl 100

# 4. TC 出口处理
tc qdisc add dev eth0 root руе ingress
tc filter add dev eth0 egress bpf obj tc_egress.bpf.o sec egress
```

### 6.3 流量分流示例

```bash
# 场景: Web 流量 vs 其他流量

# XDP 分类
cat > xdp_classifier.bpf.c << 'EOF'
SEC("xdp")
int xdp_classify(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth = data;
    struct iphdr *ip = (struct iphdr *)(eth + 1);
    struct tcphdr *tcp = (struct tcphdr *)(ip + 1);
    
    /* HTTP/HTTPS 流量: port 80 or 443 */
    if (ip->protocol == IPPROTO_TCP) {
        if (tcp->dest == 80 || tcp->dest == 443) {
            /* Web 流量: 设置 mark 后重定向 */
            bpf_skb_change_proto(skb, bpf_htons(ETH_P_IP), 0);
            return XDP_REDIRECT;
        }
    }
    
    /* 其他流量: 正常处理 */
    return XDP_PASS;
}
EOF

# 编译加载
clang -O2 -target bpf -c xdp_classifier.bpf.c
ip link set dev eth0 xdp obj xdp_classifier.bpf.o

# VPP 处理 Web 流量
vpp# classify table add table-index 10 mask l4 dst port
vpp# classify session table-index 10 match ip proto tcp dst port 80 action classify-next-node hairpin-node
```

## 7. 工具链与调试

### 7.1 BPF Tool 链

```bash
# bpftool 使用
bpftool map show
bpftool map dump id <id>
bpftool prog show

# 跟踪 eBPF 程序
bpftrace -e 'kprobe:vpp_classify_packet { printf("packet classified\n"); }'

# perf 分析
perf record -e 'bpf:*' -a
```

### 7.2 VPP eBPF 调试

```bash
# VPP 显示 eBPF 状态
vpp# show ebpf

# 示例输出:
# eBPF:
#   XDP programs:
#     eth0: xdp_firewall (active)
#     eth1: xdp_router (active)
#   Maps:
#     ct_map: 50000 entries
#     policy_map: 1000 entries
#   Counters:
#     dropped: 1000
#     passed: 999000
```

### 7.3 常见问题排查

```bash
# 问题: XDP 程序不加载
# 解决:
ip link set dev eth0 xdp off
ip link set dev eth0 xdp obj xdp_firewall.bpf.o

# 问题: AF_XDP 性能低
# 解决:
ethtool -G eth0 rx 4096 tx 4096
ethtool -C eth0 rx-usecs 100

# 问题: VPP 无法读取 eBPF map
# 解决:
bpftool map pin id <map_id> /sys/fs/bpf/vpp_ct_map
vpp# ebpf map-pin ct_map /sys/fs/bpf/vpp_ct_map
```

## 8. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP + eBPF 总结                          │
│                                                              │
│  协同优势:                                                   │
│  - eBPF: 早期过滤/采样/可见性                              │
│  - VPP: 深度处理/完整协议栈                                │
│  - 互补: 极低延迟 + 高吞吐量                               │
│                                                              │
│  集成模式:                                                   │
│  1. XDP ──► VPP (前端过滤)                                 │
│  2. TC ────► VPP (流量标记)                                │
│  3. AF_XDP ──► VPP (零拷贝)                                │
│  4. eBPF ──► VPP (卸载辅助)                                │
│                                                              │
│  最佳场景:                                                   │
│  - DDoS 防护 (XDP 过滤)                                    │
│  - 流量镜像 (XDP sampling)                                  │
│  - 高性能 NAT (eBPF CT + VPP NAT)                          │
│  - 安全检测 (XDP + VPP DPI)                                │
│  - 5G UPF (eBPF 加速 + VPP 转发)                           │
│                                                              │
│  工具链:                                                     │
│  - bpftool, bpftrace, clang, llc                          │
│  - VPP ebpf 插件                                            │
│  - kernel >= 5.8 (AF_XDP 成熟)                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 参考资源

- [XDP Documentation](https://www.kernel.org/doc/html/latest/networking/xdp.html)
- [AF_XDP Socket](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [VPP eBPF Support](https://wiki.fd.io/view/VPP/eBPF)
- [BPF Performance Tools](http://www.brendangregg.com/bpf-performance-tools-book.html)
