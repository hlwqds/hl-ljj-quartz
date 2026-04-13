---
title: "DPDK 第三十八章：DPDK + eBPF：XDP 与 AF_XDP 协同"
date: 2026-04-09 16:30:00
tags: [dpdk, ebpf, xdp, af_xdp, kernel-bypass, networking]
description: "深入解析 eBPF 与 DPDK 的协同架构：XDP 基础、AF_XDP 零拷贝、DPDK+eBPF 集成与性能对比"
---

# DPDK 第三十八章：DPDK + eBPF：XDP 与 AF_XDP 协同

> [!abstract] 核心要点
> eBPF (extended Berkeley Packet Filter) 是 Linux 内核的可编程数据面。本章解析 XDP (eXpress Data Path)、AF_XDP 零拷贝机制，以及 DPDK 与 eBPF 的协同架构。

## 1. eBPF 概述

### 1.1 什么是 eBPF

eBPF 是 Linux 内核的沙箱执行环境：

- **安全**：内核验证器检查所有程序
- **高效**：JIT 编译为原生指令
- **可编程**：动态加载/卸载程序
- **内核集成**：访问内核数据结构

### 1.2 eBPF vs DPDK

| 特性 | eBPF | DPDK |
|------|------|------|
| **运行位置** | 内核 | 用户态 |
| **权限需求** | CAP_BPF (非特权) | root + hugepages |
| **网络路径** | 内核协议栈入口 | 完全绕过内核 |
| **可编程性** | 有限制 | 完全控制 |
| **包处理** | 需通过 kernel | 直接 DMA |
| **适用场景** | 观测、过滤、负载均衡 | 极致性能 |

### 1.3 eBPF 生态

```
┌─────────────────────────────────────────────────────────────┐
│                      User Space                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐ │
│  │  Cilium     │  │  bcc        │  │  ioduafk            │ │
│  │  (k8s net)  │  │  (tools)    │  │  (tracing)          │ │
│  └─────────────┘  └─────────────┘  └─────────────────────┘ │
│                            │                                  │
│                    ┌───────▼───────┐                         │
│                    │   libbpf     │                          │
│                    │  (BPF CO-RE) │                          │
│                    └───────┬───────┘                         │
└──────────────────────────────────────────────────────────────┘
                            │
┌───────────────────────────▼──────────────────────────────────┐
│                      Kernel Space                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐   │
│  │   XDP       │  │  TC (cls)   │  │   kprobes/uprobes  │   │
│  │  (ingress)  │  │  (egress)   │  │   (tracing)        │   │
│  └─────────────┘  └─────────────┘  └─────────────────────┘   │
│                            │                                  │
│                    ┌───────▼───────┐                         │
│                    │  BPF Subsystem │                         │
│                    │  (verifier + JIT)│                      │
│                    └─────────────────┘                        │
└──────────────────────────────────────────────────────────────┘
```

## 2. XDP (eXpress Data Path)

### 2.1 XDP 概述

XDP 在**网卡驱动层**插入 eBPF 程序：

```
Packet arrives at NIC
        │
        ▼
┌───────────────────┐
│   NIC Driver      │
│   (DMA to skb)    │
└─────────┬─────────┘
          │
          ▼
┌───────────────────┐
│     XDP Hook      │  ← eBPF program runs HERE
│  (before skb      │
│   allocation)     │
└─────────┬─────────┘
          │
    ┌─────┼─────┐
    │     │     │
    ▼     ▼     ▼
  DROP  PASS  REDIRECT
```

### 2.2 XDP 动作

```c
#include <linux/bpf.h>
#include <linux/netdevice.h>

// XDP 程序的可能返回值
enum xdp_action {
    XDP_ABORTED   = 0,  // 错误，计入错误统计
    XDP_DROP      = 1,  // 丢弃包
    XDP_PASS      = 2,  // 交给内核协议栈
    XDP_TX        = 3,  // 从同一网卡发回
    XDP_REDIRECT  = 4,  // 重定向到其他接口/Tx
};
```

### 2.3 XDP 程序示例

```c
// xdp_firewall.bpf.c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

// BPF MAP：存储 ACL 规则
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 10000);
    __type(key, __u32);   // IP
    __type(value, __u8);  // action (0=drop, 1=allow)
} acl_map SEC(".maps");

// XDP 程序
SEC("xdp")
int xdp_firewall(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析 Ethernet header
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;  // Not our packet

    // 只处理 IPv4
    if (eth->h_proto != htons(ETH_P_IP))
        return XDP_PASS;

    // 解析 IP header
    struct iphdr *iph = data + sizeof(struct ethhdr);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    // 查询 ACL
    __u32 *action = bpf_map_lookup_elem(&acl_map, &iph->daddr);
    if (action) {
        if (*action == 0)
            return XDP_DROP;
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

### 2.4 编译和加载 XDP

```bash
# 编译
clang -O2 -Wall -target bpf -c xdp_firewall.bpf.c -o xdp_firewall.bpf.o

# 加载（使用 ip 或 bpftool）
ip link set dev eth0 xdp obj xdp_firewall.bpf.o sec xdp

# 查看状态
ip link show eth0
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>
#     xdp: id 123 prog

# 查看 XDP 统计
ip -s link show eth0

# 卸载
ip link set dev eth0 xdp off
```

## 3. AF_XDP

### 3.1 AF_XDP 概述

AF_XDP 是 XDP 的用户态接口，提供**零拷贝**路径：

```
Traditional XDP:
  NIC → DMA → skb → kernel stack → socket → App
                    (copy)

AF_XDP (zero-copy):
  NIC → DMA → XDP → UMEM → App
                (zero-copy, no skb)
```

### 3.2 核心概念

| 概念 | 说明 |
|------|------|
| **UMEM** | 连续内存区域，packet 存储 |
| **Fill Queue** | NIC → UMEM 的 Descriptor Ring |
| **Completion Queue** | UMEM → NIC 的 Descriptor Ring |
| **RX Queue** | 接收队列 |
| **TX Queue** | 发送队列 |
| **Chunk** | UMEM 内存块大小（默认 4KB） |

### 3.3 UMEM 和 Queue 布局

```
┌─────────────────────────────────────────────────────────────┐
│                        UMEM                                │
│  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐  │
│  │ Chunk0 │ │ Chunk1 │ │ Chunk2 │ │ Chunk3 │ │ ChunkN │  │
│  │ (4KB)  │ │ (4KB)  │ │ (4KB)  │ │ (4KB)  │ │ (4KB)  │  │
│  └────────┘ └────────┘ └────────┘ └────────┘ └────────┘  │
└─────────────────────────────────────────────────────────────┘
          ▲            │           │            │
          │            ▼           │            │
    Fill Queue    RX Queue    TX Queue    Completion Queue
   (NIC→UMEM)    (App reads)  (App writes) (NIC→App)
```

### 3.4 AF_XDP 示例

```c
#include <afxdp.h>
#include <linux/if_xdp.h>
#include <rte_ethdev.h>

#define NUM_CHUNKS 4096
#define CHUNK_SIZE 4096

struct xsk_umem_config umem_config = {
    .fill_size = CHUNK_SIZE * 2,
    .comp_size = CHUNK_SIZE * 2,
    .frame_size = CHUNK_SIZE,
    .frame_headroom = 0,
};

struct xsk_socket_config socket_config = {
    .rx_size = XSK_RING_PROD__DEFAULT_NUM_DESCS,
    .tx_size = XSK_RING_CONS__DEFAULT_NUM_DESCS,
    .libxdp_flags = XSK_LIBXDP_FLAGS__INHIBIT_PROG_LOAD,
    .xdp_flags = XDP_USE_NEED_MORE | XDP_SHARED_UMEM,
    .bind_flags = XDP_COPY,
};

int main(int argc, char **argv)
{
    int port_id = 0;
    struct xsk_ring_prod fq;   // Fill queue
    struct xsk_ring_cons cq;   // Completion queue
    struct xsk_ring_cons rx;   // RX queue
    struct xsk_ring_prod tx;   // TX queue
    struct xsk_umem *umem;
    struct xsk_socket *xsk;
    void *buffer;
    int ret;

    // 1. 创建 UMEM
    ret = posix_memalign(&buffer, getpagesize(),
                         NUM_CHUNKS * CHUNK_SIZE);
    if (ret) return ret;

    umem = xsk_umem__create(buffer,
                             NUM_CHUNKS * CHUNK_SIZE,
                             &fq, &cq, &umem_config);

    // 2. 初始化 Fill Queue（预填充 buffers）
    struct xsk_ring_prod *fill = &fq;
    uint64_t *fill_desc;
    unsigned int i;
    for (i = 0; i < NUM_CHUNKS - 1; i++) {
        fill_desc = xsk_ring_prod__fill_addr(fill);
        *fill_desc = i * CHUNK_SIZE;
    }
    xsk_ring_prod__submit(fill, NUM_CHUNKS - 1);

    // 3. 创建 AF_XDP socket
    ret = xsk_socket__create(&xsk, "eth0", 0, umem,
                             &rx, &tx, &socket_config);
    if (ret) return ret;

    // 4. 接收包
    while (1) {
        // 处理 RX
        unsigned int rcvd = xsk_ring_cons__peek(&rx, 64, &rx_idx);
        if (rcvd > 0) {
            struct xdp_desc *desc = xsk_ring_cons__rx_desc(&rx, rx_idx);

            for (i = 0; i < rcvd; i++) {
                void *pkt = xsk_umem__get_data(buffer, desc[i].addr);
                process_packet(pkt, desc[i].len);

                // 重新填充
                fill_desc = xsk_ring_prod__fill_addr(fill);
                *fill_desc = desc[i].addr;
            }
            xsk_ring_cons__release(&rx, rcvd);
            xsk_ring_prod__submit(fill, rcvd);

            // 发送（如果有）
            if (xsk_ring_prod__needs_tx(&tx)) {
                unsigned int tx_idx;
                struct xdp_desc *tx_desc = xsk_ring_prod__tx_desc(&tx, &tx_idx);
                // setup tx_desc...
                xsk_ring_prod__submit(&tx, 1);
            }
        }
    }

    xsk_socket__delete(xsk);
    xsk_umem__delete(umem);
}
```

## 4. DPDK + XDP

### 4.1 DPDK 对 XDP 的支持

DPDK 18.11+ 支持 XDP 作为 ethdev poll mode driver：

```bash
# 加载 XDP PMD
modprobe xdpdump

# 或者在内核配置中启用
# CONFIG_BPF_JIT=y
# CONFIG_XDP_SOCKETS=y
```

### 4.2 XDP PMD 工作流程

```c
#include <rte_ethdev.h>
#include <rte_bus_vdev.h>

// 启动 XDP PMD
int main(int argc, char **argv)
{
    // 初始化 EAL
    rte_eal_init(argc, argv);

    // 创建设备（XDP socket 作为 ethdev）
    // 注意：这需要内核支持 AF_XDP
    rte_vdev_init("net_xdp_dummy", NULL);

    // 枚举端口
    uint16_t port_id = rte_eth_find_free_port();
    rte_eth_dev_configure(port_id, 1, 1, &port_conf);

    // 收发包
    struct rte_mbuf *pkts[32];
    uint16_t nb_rx = rte_eth_rx_burst(port_id, 0, pkts, 32);
    // ...
}
```

### 4.3 与 DPDK rte_flow 集成

```c
// XDP 处理不了的包交给 DPDK 处理
// 需要内核 5.10+ 的 xdp_shared_redirect

// 在 XDP 程序中重定向到 AF_XDP socket
SEC("xdp")
int xdp_redirect_map(struct xdp_md *ctx)
{
    struct xsk *xsk = bpf_map_lookup_elem(&xsks_map, &ctx->rx_queue_index);
    if (!xsk)
        return XDP_PASS;

    return xsk_redirect(xsk, XDP_COPY);  // 或 XDP_ZERO_COPY
}
```

## 5. AF_XDP vs libpcap vs DPDK

### 5.1 性能对比

| 机制 | 吞吐量 | CPU 开销 | 延迟 | 复杂度 |
|------|--------|---------|------|--------|
| **libpcap** | ~500Kpps | 高 | 高 | 低 |
| **AF_XDP** | ~10Mpps | 中 | 中 | 中 |
| **AF_XDP (zero-copy) | ~15Mpps | 中低 | 低 | 高 |
| **DPDK** | ~30Mpps+ | 低 | 最低 | 高 |

### 5.2 选择指南

```
包捕获场景选型：
                    │
        包量大吗？（>1Mpps）
            │
      ┌─────┴─────┐
      │Yes        │No
      ▼           ▼
  AF_XDP       libpcap
  (zero-copy)  (简单场景)

极致性能场景：
      │
      ▼
    DPDK
  (>10Mpps)

需要内核协议栈：
      │
      ▼
    AF_XDP
  (XDP_PASS)
```

## 6. 实际案例：负载均衡器

### 6.1 XDP 负载均衡器

```c
// lb_xdp.bpf.c
#include <linux/bpf.h>
#include <linux/in.h>

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __type(key, __u32);
    __type(value, __u32);  // backend IP
    __uint(max_entries, 256);
} backends SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __type(key, __u32);    // client IP
    __type(value, __u32);  // selected backend index
    __uint(max_entries, 100000);
} client_map SEC(".maps");

SEC("xdp")
int lb(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end) return XDP_PASS;

    struct iphdr *iph = data + sizeof(*eth);
    if ((void *)(iph + 1) > data_end) return XDP_PASS;

    // 只处理 TCP
    if (iph->protocol != IPPROTO_TCP) return XDP_PASS;

    // 读取或创建 backend 选择
    __u32 key = iph->daddr;
    __u32 *backend_idx = bpf_map_lookup_elem(&client_map, &key);
    if (!backend_idx) {
        *backend_idx = key % 256;  // hash
        bpf_map_update_elem(&client_map, &key, backend_idx, BPF_ANY);
    }

    // 获取 backend IP
    __u32 backend_ip = *(__u32 *)bpf_map_lookup_elem(&backends, backend_idx);

    // 修改目的 IP
    iph->daddr = backend_ip;
    iph->check = 0;  // 需要正确计算

    // 修改以太网目的地址（需要 ARP 或 MACVLAN）
    return XDP_PASS;
}
```

### 6.2 性能优化

```bash
# 1. 使用单队列绑定到特定 CPU
ip link set eth0 xdp obj lb.bpf.o sec xdp

# 2. 启用 zero-copy（需要网卡驱动支持）
ethtool -L eth0 combined 1

# 3. 检查是否使用 zero-copy
cat /proc/net/xdp/stats
# ZC hits: 12345678
# Misses: 1234
```

## 7. 总结

DPDK 与 eBPF 的协同提供了灵活性与性能的平衡：

1. **XDP**：内核快速路径，在 DMA 后最早位置处理
2. **AF_XDP**：零拷贝用户态访问，介于两者之间
3. **DPDK**：极致性能，完全绕过内核
4. **分层策略**：XDP 处理简单任务，DPDK 处理复杂任务

---

## 参考资源

- [XDP 官方文档](https://www.kernel.org/doc/html/latest/networking/xdp.html)
- [AF_XDP ( Socket )](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [libbpf](https://github.com/libbpf/libbpf)
- [bcc - BPF Compiler Collection](https://github.com/iovisor/bcc)
