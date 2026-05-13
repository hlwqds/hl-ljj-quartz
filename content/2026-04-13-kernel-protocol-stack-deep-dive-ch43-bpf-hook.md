---
title: "Kernel Protocol Stack 深度探索 (四十三)：Linux BPF 网络钩子"
date: 2026-04-13
tags: [linux, kernel, networking, series, bpf, tc, cls-bpf, schedcls, netfilter-ebpf, xdp, ebpf]
description: "深入解析 Linux BPF 网络钩子——TC (Traffic Control) BPF 的 cls_bpf/sched_bpf、XDP BPF、nftables eBPF 字节码、BPF_PROG_RUN 与 netdev hook 机制，以及 BPF 网络钩子与传统 iptables 的性能对比"
---

> [!info] Kernel Protocol Stack 深度探索系列
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
> 42. [[2026-04-13-kernel-protocol-stack-deep-dive-ch42-tso|第四十二章：TSO 与 UFO]]
> 43. **第四十三章：Linux BPF 网络钩子**
> 44. [[2026-04-13-kernel-protocol-stack-deep-dive-ch44-offload|第四十四章：硬件 offload]]
> 45. [[2026-04-13-kernel-protocol-stack-deep-dive-ch45-tuning|第四十五章：网络性能调优]]

---

## 1. Linux BPF 网络钩子概述

Linux 内核提供了**多个可编程 BPF 钩子点**用于网络数据包处理：

```
数据包接收路径:

  网卡驱动 RX 队列
        │
        ├──► [XDP hook] ← 最早的可编程点（驱动层）
        │
        ▼
      GRO 合并
        │
        ▼
  netif_receive_skb()
        │
        ├──► [TC ingress (cls_bpf)] ← 协议栈入口
        │
        ▼
  NF_INET_PRE_ROUTING (Netfilter)
        │
        ▼
  IP Routing
        │
        ├──► [TC egress (scheda_bpf)] ← 转发/本地发出
        │
        ▼
  NF_INET_POST_ROUTING (Netfilter)
        │
        ▼
  网卡驱动 TX 队列
```

### 1.1 BPF 钩子类型

| 钩子 | 位置 | 程序类型 | 典型用途 |
|------|------|---------|---------|
| **XDP** | 驱动层（最早） | `BPF_PROG_TYPE_XDP` | DDoS 防护、包过滤、转发 |
| **TC cls_bpf** | TC ingress | `BPF_PROG_TYPE_SCHED_CLS` | 流量分类、镜像、负载均衡 |
| **TC sched_bpf** | TC egress qdisc | `BPF_PROG_TYPE_SCHED_CLS` | 队列调度、丢包 |
| **Flow dissector** | IP 层之前 | `BPF_PROG_TYPE_FLOW_DISSECTOR` | 自定义协议解析 |
| **Cgroup sock** | Socket 层 | `BPF_PROG_TYPE_CGROUP_SOCK` | 容器网络策略 |

---

## 2. TC BPF：cls_bpf

### 2.1 TC 框架与 BPF 的关系

TC（Traffic Control）是 Linux 的流量控制框架，包含：

- **qdisc**：队列调度算法（pfifo_fast, HTB, FQ-CoDel 等）
- **class**：类别（HTB 的层次结构）
- **filter**：分类器（u32, fw, bpf 等）

BPF 作为一种**可编程的 filter**，通过 `cls_bpf` 接入 TC：

```
                    ┌─────────────────────────────────────┐
                    │             TC 框架                 │
                    │                                     │
  skb ──────► [filter] ───► [classid] ───► [qdisc] ───► TX │
                    │                                     │
                    │  ┌──────────────────┐                │
                    └──│  cls_bpf         │◄── eBPF 程序  │
                       │  (BPF classifier) │               │
                       └──────────────────┘                │
```

### 2.2 cls_bpf 加载

使用 `tc` 命令加载 cls_bpf 程序：

```bash
# 创建一个 HTB qdisc（根 qdisc）
tc qdisc add dev eth0 root handle 1: htb

# 添加一个 class
tc class add dev eth0 parent 1: classid 1:1 htb rate 1000Mbps

# 附加 cls_bpf 程序到 ingress 钩子
tc filter add dev eth0 ingress \
    bpf obj prog.o sec classifier \
    da                      # da = 直接动作（无需后续分类器）
    prio 1                  # 优先级

# 附加 cls_bpf 程序到 egress 钩子
tc filter add dev eth0 egress \
    bpf obj prog.o sec classifier \
    da
    prio 1
```

### 2.3 cls_bpf 程序结构

```c
// cls_bpf.c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <pbt/bpf_helpers.h>

// 1. 定义 MAP（用于计数、策略查找等）
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);       // 源 IP
    __type(value, __u64);     // 字节计数
    __uint(max_entries, 1024);
} stats_map SEC(".maps");

// 2. 定义 cls_bpf 分类器函数（返回 TC_ACT_*）
SEC("classifier")
int cls_main(struct __sk_buff *skb)
{
    void *data = (void *)(long)skb->data;
    void *data_end = (void *)(long)skb->data_end;

    // 解析 Ethernet 头
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return TC_ACT_UNSPEC;  // 交给后续 filter

    // 只处理 IPv4
    if (eth->h_proto != htons(ETH_P_IP))
        return TC_ACT_UNSPEC;

    // 解析 IP 头
    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return TC_ACT_UNSPEC;

    // 只处理 TCP
    if (ip->protocol != IPPROTO_TCP)
        return TC_ACT_UNSPEC;

    // 解析 TCP 头
    struct tcphdr *tcp = (void *)((char *)ip + ip->ihl * 4);
    if ((void *)(tcp + 1) > data_end)
        return TC_ACT_UNSPEC;

    // 根据源 IP 统计流量
    __u32 src_ip = ip->saddr;
    __u64 *cnt = bpf_map_lookup_elem(&stats_map, &src_ip);
    if (cnt) {
        __sync_fetch_and_add(cnt, skb->len);
    }

    // 返回 TC_ACT_OK 表示放行
    return TC_ACT_OK;
}

// 3. 定义直接动作（da = direct action）
//    da 模式下，返回值就是最终动作
SEC("classifier")
int cls_da(struct __sk_buff *skb)
{
    // 返回 TC_ACT_SHOT 表示丢包
    // 返回 TC_ACT_OK 表示放行
    // 返回 TC_ACT_REDIRECT 表示重定向到其他设备/队列
    return TC_ACT_OK;
}

char _license[] SEC("license") = "GPL";
```

### 2.4 cls_bpf 返回值（TC_ACT_*）

```c
// include/uapi/linux/pkt_cls.h

TC_ACT_UNSPEC       /* 未指定：交给后续 filter 处理 */
TC_ACT_OK           /* 放行：skb 通过 */
TC_ACT_SHOT         /* 丢包：丢弃 skb */
TC_ACT_RECLASSIFY   /* 重新分类：回到 qdisc 重匹配 */
TC_ACT_STOLEN       /* 偷走：像放行但调用者不能再访问 skb */
TC_ACT_QUEUED        /* 入队：交给 gso 分片等 */
TC_ACT_REDIRECT      /* 重定向：通过 skb_redirect_peer() 发送 */
```

### 2.5 TC 钩子与 XDP 的区别

| 特性 | XDP | TC cls_bpf (ingress) |
|------|-----|---------------------|
| **执行位置** | 驱动层（更早） | netif_receive_skb 后（协议栈入口） |
| **访问 skb** | raw packet data（通过 xdp_md） | 完整 skb |
| **性能** | ~14+ Mpps | ~5-10 Mpps |
| **修改 skb** | 不能（只能替换） | 可以（push/pop 头） |
| **GVisor/隧道** | 不能处理隧道封装包 | 可以（封装后） |
| **对等重定向** | `bpf_redirect()` | `skb_redirect_peer()` |

---

## 3. TC 调度 BPF（sched_bpf）

### 3.1 sched_bpf 位置

`schecls_bpf` 挂在 **egress qdisc** 之后、网卡驱动之前，用于队列调度：

```
用户进程
    │
    ▼
socket send buffer
    │
    ▼
TCP 协议栈
    │
    ▼
netdevice egress (dev_queue_xmit)
    │
    ├──► [qdisc dequeue] → 取出下一个 skb
    │
    ├──► [scheda_bpf hook] ← BPF 调度程序
    │
    ▼
网卡驱动 TX 队列
```

### 3.2 sched_bpf 程序

```c
// sched_bpf.c
SEC("schedcls_ingress")
int sched_main(struct __sk_buff *skb)
{
    // sched_bpf 可以：
    // 1. 丢包（TC_ACT_SHOT）
    // 2. 修改 skb 的 priority/pv_qos
    // 3. 直接放行（TC_ACT_OK）

    // 应用场景：RED/ECN 调度、自定义 AQM
    return TC_ACT_OK;
}
```

加载方式：

```bash
# 在 egress qdisc 上附加 sched_bpf
tc qdisc add dev eth0 root handle 1: fq_codel
tc filter add dev eth0 egress \
    bpf obj sched_bpf.o sec schedcls_egress \
    prio 1
```

---

## 4. BPF 程序的 Attach 目标

### 4.1 netdev hook 注册

BPF 程序通过 `bpf_prog` 的 `attach_btf_id` 和 `expected_attach_type` 关联到钩子：

```c
// net/sched/cls_bpf.c
static int cls_bpf_progate_from_bpf(struct net *net,
                                     struct bpf_prog *prog,
                                     struct tcf_result *result)
{
    // prog->aux->dst_nginx: 指向 netdev
    // prog->expected_attach_type: TC
    // 挂入 tc_ingress_ops 或 tc_egress_ops
}
```

### 4.2 查看已加载的 BPF 程序

```bash
# 查看所有网络 BPF 程序
bpftool net show

# 输出示例：
# xdp:
#   eth0(5) driver id 1234 ← XDP 程序
# tc:
#   eth0(4) ingress cls_bpf/1234 ← TC ingress
#   eth0(5) egress cls_bpf/1235 ← TC egress

# 查看某个设备的 TC filter
tc filter show dev eth0 ingress
```

---

## 5. nftables eBPF 后端

### 5.1 nftables 与 BPF 的关系

nftables 4.19+ 支持使用 **BPF 程序**作为表达式：

```
nftables 规则:
  table inet filter {
    chain input {
      type filter hook input priority 0; policy accept;

      # 使用 BPF 程序过滤
      meta iifname "eth0" bpf prog load verdict filter_bpf.o main_flow_blocking

      # 或者内联 BPF（受限）
      ct state established ct state related accept
    }
  }
```

### 5.2 nftables 字节码 vs eBPF

nftables 的内部实现将规则编译成 **字节码**，然后由内核解释执行。对于复杂的规则，可以直接编写 eBPF：

```bash
# nftables 使用 BPF 程序作为规则表达式
nft add filter block_bpf {
    typeof ip saddr @blocklist
}

# 加载 BPF 程序
nft add rule inet filter input bpf obj prog.o sec test
```

---

## 6. BPF 网络钩子的性能

### 6.1 cls_bpf vs iptables 性能对比

| 指标 | iptables | cls_bpf (TC) |
|------|---------|--------------|
| **单规则吞吐** | ~2-3 Mpps/CPU | ~8-12 Mpps/CPU |
| **扩展匹配** | 灵活（string, geoip 等） | 受限（需自己解析） |
| **状态维护** | conntrack 集成 | 需要 BPF map 自己维护 |
| **灵活性** | 规则描述能力强 | 程序化，任意逻辑 |

### 6.2 高性能包处理的 BPF 组合

 Cilium 使用的典型组合：

```
XDP (drop/sockmap) + TC (transparent proxy) + sk_lookup (socket redirect)
```

XDP 处理高速路径（DDoS 过滤、负载均衡），TC 处理策略执行和透明代理：

```c
// Cilium 典型的 XDP 负载均衡
SEC("xdp")
int xdp_lb(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    struct ethhdr *eth = data;

    // 查 BPF map 获取 service → backend
    struct lb4_key key = { .addr = ip->daddr, .port = tcp->dest };
    struct lb4_backend *backend = bpf_map_lookup_elem(&LB_MAP, &key);

    if (backend) {
        // 修改目的地址为 backend IP
        ip->daddr = backend->addr;
        return XDP_TX;  // 从同一网卡发回
    }

    return XDP_PASS;  // 未找到，走正常协议栈
}
```

---

## 7. 总结

Linux BPF 网络钩子提供了从**驱动层（XDP）到协议栈入口（TC ingress）到协议栈出口（TC egress）** 的完整可编程覆盖：

- **XDP**：最早钩子，最高性能，适合包过滤/重定向/DDoS 防护
- **TC cls_bpf**：协议栈入口，适合流量分类、镜像、透明代理
- **TC sched_bpf**：出口调度，适合丢包、AQM、队列管理
- **BPF map**：状态共享，连接计数、策略查找

相比 iptables，BPF 网络钩子在保持一定灵活性的同时，性能提升 3-5 倍，是现代云原生网络（Cilium、Katran）的核心基础设施。
