---
title: AF_XDP 深度探索 Ch1：架构与原理
date: 2026-04-25 09:00:00
tags: [AF_XDP, XDP, eBPF, High Performance Networking, DPDK, io_uring, Zero Copy, Socket, Kernel Bypass, Linux, NIC, Packet Processing]
description: 深入解析 AF_XDP（Express Data Path）架构：XDP 基础、UMEM、队列映射、零拷贝机制，以及与 DPDK/io_uring 的定位差异。
---

# AF_XDP 深度探索 Ch1：架构与原理

## 1. 为什么需要 AF_XDP

### 1.1 网络性能演进路径

```
Linux 网络数据路径性能对比：

┌──────────────────────────────────────────────────────────────────────┐
│                      网络 I/O 性能演进                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   传统内核网络栈：                                                    │
│   NIC → 中断 → ksoftirqd → sk_buff → socket → 用户态                 │
│   └── 瓶颈：中断延迟 + 多次内存拷贝 + 内核锁 + 上下文切换              │
│       延迟：~50-100us，CPU 开销大                                     │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────────┐ │
│   │  DPDK：                                                         │ │
│   │  NIC → PMD (轮询) → 用户态大页 → 应用                           │ │
│   │  └── 零中断 + 零拷贝 + 无内核参与                               │ │
│   │      延迟：~5-10us，CPU 开销低，但独占 NIC，生态封闭            │ │
│   └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────────┐ │
│   │  io_uring (网络)：                                              │ │
│   │  NIC → 中断 → io_uring → 应用（异步 I/O）                      │ │
│   │  └── 减少 syscall，但依赖内核网络栈                            │ │
│   │      延迟：~20-30us，通用性好                                   │ │
│   └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│   ┌────────────────────────────────────────────────────────────────┐ │
│   │  AF_XDP：                                                       │ │
│   │  NIC → XDP (内核) → UMEM → 用户态                               │ │
│   │  └── XDP 早期分流 + UMEM 零拷贝                                │ │
│   │      延迟：~5-15us，兼得高性能 + 内核集成                       │ │
│   └────────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘

AF_XDP 的设计目标：
  1. 零拷贝：数据包直接到用户态，避免 sk_buff 拷贝
  2. 低延迟：XDP 早期处理，减少中断和调度
  3. 可编程：BPF 灵活控制数据包路径
  4. 兼容内核：不需要独占 NIC，可与内核共享
```

### 1.2 AF_XDP 定位

```
AF_XDP vs DPDK vs io_uring 网络定位矩阵：

┌──────────────────────────────────────────────────────────────────────┐
│  维度           │  AF_XDP           │  DPDK            │  io_uring  │
├──────────────────────────────────────────────────────────────────────┤
│  数据路径       │  内核 + 用户态     │  纯用户态         │  内核主导  │
│  NIC 独占       │  否（可共享）      │  是              │  否        │
│  零拷贝         │  是               │  是              │  否        │
│  可编程性       │  BPF              │  无（固定路径）  │  无        │
│  延迟           │  ~5-15us          │  ~3-8us          │  ~20-30us  │
│  CPU 占用       │  低               │  最低            │  中等      │
│  开发难度       │  中（BPF）        │  高（DPDK 栈）   │  低        │
│  内核协议栈     │  部分绕过         │  完全绕过        │  完全依赖  │
│  多队列支持     │  完整             │  完整            │  epoll     │
│  生态成熟度     │  2018+           │  成熟（10+年）   │  2019+     │
└──────────────────────────────────────────────────────────────────────┘

什么时候选 AF_XDP：
  · 需要高性能但不想抛弃内核协议栈
  · 需要 BPF 灵活处理（过滤/修改/分流）
  · 多租户场景（不能独占 NIC）
  · 与内核网络服务共存（iptables/nftables）
```

---

## 2. XDP 基础

### 2.1 XDP 是什么

```
XDP（eXpress Data Path）：

  · 位置：内核网络栈最早期，在 DMA 之后、sk_buff 创建之前
  · 时机：网卡收到数据包，立即交给 XDP BPF 程序处理
  · 特点：最早可见数据包、最短路径

XDP 处理阶段：

  ┌────────────────────────────────────────────────────────────────┐
  │  NIC 收到数据包                                                │
  │       │                                                       │
  │       ▼                                                       │
  │  ┌─────────────────────────────────────────────────────────┐   │
  │  │  DMA 到内核内存（ring buffer）                        │   │
  │  └─────────────────────────────────────────────────────────┘   │
  │       │                                                       │
  │       ▼ [XDP 触发点]                                          │
  │  ┌─────────────────────────────────────────────────────────┐   │
  │  │  XDP BPF 程序执行（数据包头指针，sk_buff 未创建）     │   │
  │  │                                                         │   │
  │  │  返回值：                                                │   │
  │  │    XDP_PASS  → 交给内核继续处理                         │   │
  │  │    XDP_DROP  → 丢弃（防火墙/DDoS）                      │   │
  │  │    XDP_REDIRECT → 重定向到其他接口/UMEM/AF_XDP         │   │
  │  │    XDP_TX    → 直接从原网卡发出                         │   │
  │  └─────────────────────────────────────────────────────────┘   │
  │       │                                                       │
  │       ▼                                                       │
  │  创建 sk_buff（如果没有被 XDP 处理）                         │
  │       │                                                       │
  │       ▼                                                       │
  │  内核协议栈（TCP/IP）                                         │
  └────────────────────────────────────────────────────────────────┘

关键优势：
  1. 最早期处理：在所有内核基础设施之前
  2. 无 sk_buff：直接操作原始数据包内存
  3. BPF JIT：编译后 native 执行，无解释器开销
  4. 可重定向：XDP_REDIRECT 可送到 AF_XDP、NIC、其他 BPF
```

### 2.2 XDP 程序结构

```c
// xdp_prog.c — 简单 XDP 程序

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

// XDP 许可（必需）
SEC("xdp")
int xdp_drop_tcp(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end  = (void *)(long)ctx->data_end;

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

    // 丢弃 TCP 包（示例）
    if (iph->protocol == IPPROTO_TCP)
        return XDP_DROP;

    // 放行其他
    return XDP_PASS;
}

// 加载 XDP 程序
// $ clang -target bpf -O2 -c xdp_prog.c
// $ ip link set dev eth0 xdp obj xdp_prog.o sec xdp
```

---

## 3. AF_XDP 架构

### 3.1 AF_XDP 工作原理

```
AF_XDP（Address Family XDP）：

  · 套接字类型：AF_XDP
  · 核心机制：XDP 重定向 + UMEM 共享内存
  · 数据路径：NIC → XDP → UMEM → 用户态应用

架构图：

  ┌─────────────────────────────────────────────────────────────────┐
  │                         用户态                                  │
  │  ┌────────────────┐    ┌────────────────┐                      │
  │  │   应用进程     │    │   应用进程     │                      │
  │  │  (socket AF_XDP)│    │  (socket AF_XDP)│                     │
  │  └───────┬────────┘    └───────┬────────┘                      │
  │          │                     │                                │
  │          └──────────┬──────────┘                                │
  │                     │                                           │
  │              ┌───────▼───────┐                                   │
  │              │     UMEM     │ ←── 用户态内存（大页）            │
  │              │ (共享 ring)  │                                   │
  │              └───────┬───────┘                                   │
  └──────────────────────┼──────────────────────────────────────────┘
                         │
                         │ XDP_REDIRECT
  ┌──────────────────────┼──────────────────────────────────────────┐
  │                      ▼                    内核                  │
  │              ┌───────────────┐                                  │
  │              │  XDP BPF 程序 │ ←── 可编程过滤/修改/分流        │
  │              └───────┬───────┘                                  │
  │                      │                                           │
  │              ┌───────▼───────┐                                   │
  │              │  NIC DMA ring │                                   │
  │              └───────┬───────┘                                   │
  └──────────────────────┼──────────────────────────────────────────┘
                         │
                         ▼
                  ┌─────────────┐
                  │    NIC     │
                  └─────────────┘

UMEM（Unified Memory）：
  · 预先分配的大页内存池
  · 被 NIC DMA 和用户态共享
  · 通过 FILL/COMPLETION/READY/RECEIVE 四个 ring 管理
```

### 3.2 UMEM 与四大 Ring

```
UMEM 内存布局：

┌─────────────────────────────────────────────────────────────────┐
│                        UMEM                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │  FILL RING  │  │    FQ RING  │  │     RQ RING │              │
│  │  (内核→用户)│  │ (用户→内核) │  │  (RX 队列) │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     CHUNK 池                              │   │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐              │   │
│  │  │ chunk0 │ │ chunk1 │ │ chunk2 │ │ chunk3 │  ...        │   │
│  │  │  4KB   │ │  4KB   │ │  4KB   │ │  4KB   │              │   │
│  │  └────────┘ └────────┘ └────────┘ └────────┘              │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                     CQ RINGS                              │   │
│  │  ┌──────────────┐ ┌──────────────┐                        │   │
│  │  │  RX CQ RING │ │  TX CQ RING  │                        │   │
│  │  └──────────────┘ └──────────────┘                        │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘

四大 Ring（都是无锁 SPSC 生产者/消费者）：

  1. FILL RING（内核 → 用户）
     · 供 NIC 驱动填充（接收新数据包）
     · 用户态消费（取出可用 chunk）
     · 元素：chunk 地址

  2. REQEUST (FQ) RING（用户 → 内核）
     · 用户态提交（请求发送）
     · 内核消费（取走待发数据）
     · 元素：chunk 地址

  3. RECEIVE (RQ) RING（接收队列）
     · 接收准备好给用户态的数据
     · 用户态消费
     · 元素：chunk 地址 + 元数据

  4. COMPLETION (CQ) RING（完成队列）
     · 发送完成通知
     · 用户态消费
     · 元素：chunk 地址

UMEM Chunk：
  · 默认 4KB（可配置）
  · 对齐：64 字节（Cache line）
  · 预注册：大页内存，NIC 可直接 DMA
```

### 3.3 AF_XDP 套接字创建流程

```c
// af_xdp_create.c — AF_XDP 套接字创建流程

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/if_xdp.h>
#include <linux/if.h>
#include <sys/mman.h>

#define UMEM_CHUNK_SIZE 4096
#define UMEM_NUM_CHUNKS 4096
#define FILL_RING_SIZE  1024
#define COMPLETION_RING_SIZE 1024
#define RX_RING_SIZE    1024
#define TX_RING_SIZE    1024

// 创建 AF_XDP 套接字
int create_af_xdp_socket(const char *ifname, int queue_id)
{
    int sock;

    // 1. 创建 AF_XDP 套接字
    sock = socket(AF_XDP, SOCK_RAW, 0);
    if (sock < 0) {
        perror("socket(AF_XDP)");
        return -1;
    }

    // 2. 配置 UMEM
    struct xdp_mmap_offsets off;
    socklen_t optlen = sizeof(off);
    getsockopt(sock, SOL_XDP, XDP_MMAP_OFFSETS, &off, &optlen);

    // 3. 映射 UMEM 区域
    //    UMEM = 大页内存，多个 ring 共享
    struct xdp_umem_reg mr = {
        .addr = (uint64_t)umem_base,      // 大页内存地址
        .len = UMEM_CHUNK_SIZE * UMEM_NUM_CHUNKS,
        .chunk_size = UMEM_CHUNK_SIZE,
        .headroom = 0,                    // XDP 默认 headroom
        .flags = 0,
    };

    if (setsockopt(sock, SOL_XDP, XDP_UMEM_REG, &mr, sizeof(mr)) < 0) {
        perror("setsockopt(XDP_UMEM_REG)");
        return -1;
    }

    // 4. 创建 FILL RING
    struct ring_vec fq_vec = {
        .ptr = fq_ring,
        .len = FILL_RING_SIZE,
    };
    if (setsockopt(sock, SOL_XDP, XDP_PGOFF_FILL_RING, &off, sizeof(off)) < 0) {
        // ...
    }

    // 5. 创建 COMPLETION RING
    if (setsockopt(sock, SOL_XDP, XDP_PGOFF_COMPLETION_RING, &off, sizeof(off)) < 0) {
        // ...
    }

    // 6. 创建 RX RING
    struct sockaddr_xdp addr = {
        .sxdp_family = AF_XDP,
        .sxdp_flags = XDP_COPY | XDP_ZEROCOPY,  // 优先零拷贝
        .sxdp_ifindex = if_nametoindex(ifname),
        .sxdp_queue_id = queue_id,
    };

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return -1;
    }

    // 7. 映射 RX/TX ring
    // ...

    return sock;
}
```

### 3.4 XDP 程序加载与绑定

```bash
# 查看网卡 XDP 状态
ip link show eth0
# 输出类似：
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 xdp qdisc mq state UP mode
# qlen 1000
#     xdp{###}/rx/ethxdp[pid 1234]

# 加载 XDP 程序
ip link set eth0 xdp obj xdp_prog.o sec xdp

# 加载 AF_XDP 驱动的专用 XDP（驱动支持时）
ip link set eth0 xdpgeneric obj xdp_prog.o sec xdp

# 或者使用 iproute2 的内置功能
tc qdisc add dev eth0 clsact
tc filter add dev eth0 ingress bpf obj xdp_prog.o sec xdp

# 查看 XDP 日志
ip link set eth0 xdp dump
```

---

## 4. 数据路径详解

### 4.1 接收路径（RX）

```
AF_XDP 接收数据路径：

  1. NIC 收到数据包
         │
         ▼
  2. DMA 到内核内存（skb_shared_info）
         │
         ▼
  3. XDP 触发点
     ┌────────────────────────────────────────┐
     │ XDP BPF 程序执行                        │
     │   · 检查数据包头                        │
     │   · 决定：PASS / DROP / REDIRECT       │
     │                                        │
     │ 如果 REDIRECT 到 AF_XDP：              │
     │   · 查找目标 socket 的 FILL ring       │
     │   · 分配 chunk（从 UMEM）              │
     │   · 拷贝/重映射数据包到 chunk          │
     │   · 填写 RQ ring（通知用户态）          │
     └────────────────────────────────────────┘
         │
         ▼
  4. 用户态 poll AF_XDP socket
         │
         ▼
  5. 用户态从 RQ ring 取走 chunk
         │
         ▼
  6. 用户态处理数据
         │
         ▼
  7. 归还 chunk 到 FILL ring（供下次使用）

零拷贝关键：
  · 理想情况：DMA 直接到 UMEM chunk（需要 NIC + 驱动支持）
  · 回退：DMA 到临时 skb，再拷贝到 UMEM（COPY 模式）

接收代码示例：

```c
// rx_loop.c — AF_XDP 接收循环

#define BATCH_SIZE 64

int rx_loop(int sock)
{
    struct xdp_desc desc[BATCH_SIZE];
    struct pollfd pfd = { .fd = sock, .events = POLLIN };

    while (1) {
        // 等待数据包
        int ret = poll(&pfd, 1, 1000);
        if (ret < 0) continue;

        // 接收多个描述符
        int n = recvfrom(sock, desc, BATCH_SIZE, 0, NULL, NULL);
        if (n <= 0) continue;

        // 处理每个数据包
        for (int i = 0; i < n; i++) {
            void *pkt = umem_base + desc[i].addr;
            // 处理：解析/修改/转发
            process_packet(pkt, desc[i].len);
        }

        // 归还 chunks 到 FILL ring（重新填充）
        // ...
    }
}
```

### 4.2 发送路径（TX）

```
AF_XDP 发送数据路径：

  1. 用户态构造数据包（写入 UMEM chunk）
         │
         ▼
  2. 提交 chunk 到 FQ (Request) ring
         │
         ▼
  3. 内核/XDP 处理
     ┌────────────────────────────────────────┐
     │ 如果是 AF_XDP → AF_XDP（同主机）：      │
     │   · 直接从 UMEM 读取                   │
     │   · 触发 TX DMA                        │
     │                                        │
     │ 如果是转发到其他接口：                  │
     │   · 走正常网络栈或 XDP TX              │
     └────────────────────────────────────────┘
         │
         ▼
  4. 发送完成，chunk 进入 COMPLETION ring
         │
         ▼
  5. 用户态从 CQ 取走完成通知
         │
         ▼
  6. 归还 chunk 到 FILL ring（下次接收可用）
```

### 4.3 Zero-Copy 条件

```
AF_XDP 零拷贝实现条件：

┌────────────────────────────────────────────────────────────────┐
│  零拷贝依赖：                                                   │
│                                                                │
│  1. NIC + 驱动支持                                             │
│     · 需要网卡支持「本地 DMA 重映射」                           │
│     · 驱动实现 .ndo_xdp_flush_frame()                         │
│     · Intel：ice, i40e, ixgbe, igc, ice                      │
│     · Mellanox：mlx4, mlx5                                     │
│     · 其他：ticam, nfp                                         │
│                                                                │
│  2. XDP_ZEROCOPY 模式                                          │
│     · setsockopt(SOL_XDP, XDP_ZEROCOPY)                       │
│     · 失败则回退到 COPY 模式                                   │
│                                                                │
│  3. 大页内存                                                    │
│     · hugetlbfs 或 transparent hugepage                       │
│     · mmap(MAP_HUGETLB | MAP_ANONYMOUS)                      │
│     · 大小：建议 >= 2MB                                        │
│                                                                │
│  零拷贝路径：                                                   │
│    NIC DMA → UMEM chunk（无需拷贝）                           │
│                                                                │
│  COPY 模式路径：                                               │
│    NIC DMA → skb → UMEM chunk（一次拷贝）                     │
└────────────────────────────────────────────────────────────────┘
```

---

## 5. 与 io_uring 的关系

### 5.1 互补设计

```
AF_XDP 和 io_uring 的定位差异：

┌────────────────────────────────────────────────────────────────┐
│                      AF_XDP × io_uring                       │
├────────────────────────────────────────────────────────────────┤
│                                                                │
│   AF_XDP：                                                     │
│   · 专门针对网络包 I/O                                         │
│   · XDP 早期处理 + UMEM 零拷贝                                 │
│   · BPF 可编程                                                  │
│   · 适合：高速包处理、防火墙、负载均衡                         │
│                                                                │
│   io_uring：                                                   │
│   · 通用异步 I/O（文件/网络/块设备）                           │
│   · SQ/CQ ring + uring_cmd                                    │
│   · 适合：数据库、文件 I/O、NVMe                              │
│                                                                │
│   融合：                                                       │
│   ┌────────────────────────────────────────────────────────┐   │
│   │              应用层                                      │   │
│   │  ┌──────────────┐    ┌──────────────┐                │   │
│   │  │  AF_XDP     │    │  io_uring    │                │   │
│   │  │  (网络 I/O)  │    │  (存储 I/O)   │                │   │
│   │  └──────────────┘    └──────────────┘                │   │
│   │           │                  │                        │   │
│   └───────────┼──────────────────┼────────────────────────┘   │
│               │                  │                             │
│        ┌──────▼──────┐    ┌──────▼──────┐                     │
│        │  网络包处理  │    │  块设备/文件 │                     │
│        │   (XDP)     │    │  (NVMe/SSD)  │                     │
│        └─────────────┘    └─────────────┘                     │
│                                                                │
│   典型场景：                                                   │
│   · 高速网关：AF_XDP 收包 + io_uring 落盘                      │
│   · 网络存储：AF_XDP 网络路径 + io_uring NVMe/TCP             │
│   · 负载均衡：AF_XDP 快速转发 + io_uring 连接管理               │
│   · 智能网卡：AF_XDP + 硬件卸载                                 │
└────────────────────────────────────────────────────────────────┘
```

### 5.2 io_uring socket vs AF_XDP

```c
// 对比：io_uring uring_cmd vs AF_XDP

// io_uring 网络（通用）
struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
io_uring_prep_recv(sqe, sock_fd, buf, len, 0);
io_uring_submit(&ring);
// → 经过内核网络栈（协议处理）

// AF_XDP（极致性能）
struct xdp_desc desc;
recvfrom(sock_fd, &desc, 1, 0, NULL, NULL);
// → 绕过内核网络栈（XDP 早期处理）
// → UMEM 零拷贝

// 混合：AF_XDP 收包 + io_uring 发包
void hybrid_rx_tx(int xdp_sock, int io_uring_sock)
{
    // AF_XDP 高效接收
    struct xdp_desc desc[BATCH];
    int n = recvfrom(xdp_sock, desc, BATCH, 0, NULL, NULL);

    for (int i = 0; i < n; i++) {
        void *pkt = umem_base + desc[i].addr;

        // 修改/处理
        modify_packet(pkt);

        // 通过 io_uring 发送到指定连接（保持 TCP 状态机）
        struct io_uring_sqe *sqe = io_uring_get_sqe(&uring_ring);
        io_uring_prep_send(sqe, tcp_sock, pkt, desc[i].len, 0);
    }

    io_uring_submit(&uring_ring);
}
```

---

## 6. 驱动支持与限制

### 6.1 支持的网卡

```
主要支持 AF_XDP/NETDEV XDP 的网卡：

Intel：
  · i40e (X710/XL710)       — 40GbE
  · ixgbe (82599/X520)     — 10GbE
  · ice (E800 系列)        — 最新，支持完整 XDP
  · igc (i225/i226)        — 2.5GbE
  · fm10k                   — 交换机

Mellanox/NVIDIA：
  · mlx4 (ConnectX-3 Pro)  — 40/56GbE
  · mlx5 (ConnectX-4/5/6)  — 100/200/400GbE
  · 完整零拷贝支持

Cavium：
  · thunderx (LIO)          — 常用

NFP (Netronome)：
  · NFP-4000/6000          — 智能网卡

其他：
  · tigon (Broadcom)       — 部分支持
  · virtio-net             — 软件模拟（适合测试）

查看支持：
  $ cat /sys/class/net/eth0/queues/*/xdp_rxq_metadata
  $ ethtool -l eth0  # 查看队列数
```

### 6.2 限制与注意事项

```
AF_XDP 限制：

1. 多队列亲和性
   · 一个 socket 只能绑定一个 queue
   · 需要多个 socket 绑定不同队列
   · 或使用 SO_REUSEPORT + reuseport_groups

2. 内存对齐
   · chunk 地址必须对齐到 64 字节
   · 使用 posix_memalign 或 hugepage 分配

3. XDP 程序冲突
   · 一个网卡只能有一个 XDP 程序
   · 多个 socket 共享同一个 XDP

4. NIC 资源
   · 每个队列需要独立的 FILL/CQ/RQ ring
   · 内存占用较高

5. 调试复杂性
   · BPF 验证、jit 错误难调试
   · 内核/用户态 race condition

6. 零拷贝条件
   · 必须驱动支持 + NIC 支持
   · fallback 到 COPY 模式性能下降

最佳实践：
  · 使用 mlx5 或 ice 驱动（最佳支持）
  · 确保大页配置正确
  · 测试前检查 XDP 模式（generic vs native）
  · 监控 dropped packets（XDP_DROP 统计）
```

---

## 7. 快速入门

### 7.1 完整示例

```c
// af_xdp_example.c — 完整 AF_XDP 收发示例

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <sys/socket.h>
#include <linux/if_xdp.h>
#include <linux/if.h>
#include <arpa/inet.h>

#define UMEM_CHUNK_SIZE    4096
#define NUM_CHUNKS         4096
#define FILL_RING_SIZE     256
#define CQ_RING_SIZE       256
#define RX_RING_SIZE       256
#define TX_RING_SIZE       256

static volatile int running = 1;

void signal_handler(int sig) { running = 0; }

struct xdp_umem *create_umem(void *umem_base, int chunk_size, int num_chunks)
{
    struct xdp_umem *umem = calloc(1, sizeof(*umem));
    umem->base = umem_base;
    umem->chunk_size = chunk_size;
    umem->num_chunks = num_chunks;

    // 初始化 free list（所有 chunks 可用）
    umem->free_list = calloc(num_chunks, sizeof(uint64_t));
    for (int i = 0; i < num_chunks; i++)
        umem->free_list[i] = (uint64_t)umem_base + i * chunk_size;
    umem->free_count = num_chunks;

    return umem;
}

int main(int argc, char **argv)
{
    const char *ifname = "eth0";
    int queue_id = 0;

    if (argc > 1) ifname = argv[1];
    if (argc > 2) queue_id = atoi(argv[2]);

    signal(SIGINT, signal_handler);

    // 1. 分配大页内存
    int fd = open("/dev/hugepages", O_RDWR);
    size_t umem_size = UMEM_CHUNK_SIZE * NUM_CHUNKS;
    void *umem_base = mmap(NULL, umem_size, PROT_READ | PROT_WRITE,
                           MAP_SHARED | MAP_HUGETLB, fd, 0);
    if (umem_base == MAP_FAILED) {
        perror("mmap hugepages");
        // fallback 到普通内存
        umem_base = mmap(NULL, umem_size, PROT_READ | PROT_WRITE,
                         MAP_SHARED | MAP_ANONYMOUS, -1, 0);
    }

    printf("UMEM: %p, size: %zu MB\n", umem_base, umem_size / 1024 / 1024);

    // 2. 创建 AF_XDP socket
    int sock = socket(AF_XDP, SOCK_RAW, 0);
    if (sock < 0) {
        perror("socket(AF_XDP)");
        return 1;
    }

    // 3. 注册 UMEM
    struct xdp_umem_reg mr = {
        .addr = (uint64_t)umem_base,
        .len = umem_size,
        .chunk_size = UMEM_CHUNK_SIZE,
        .headroom = 0,
        .flags = 0,
    };
    if (setsockopt(sock, SOL_XDP, XDP_UMEM_REG, &mr, sizeof(mr)) < 0) {
        perror("setsockopt(XDP_UMEM_REG)");
        return 1;
    }

    // 4. 配置 rings
    struct xdp_mmap_offsets off;
    socklen_t len = sizeof(off);
    getsockopt(sock, SOL_XDP, XDP_MMAP_OFFSETS, &off, &len);

    // 创建 FILL ring
    struct xdp_ring *fill_ring = mmap(NULL, FILL_RING_SIZE * sizeof(uint64_t),
                                       PROT_READ | PROT_WRITE, MAP_SHARED, sock,
                                       XDP_PGOFF_FILL_RING + off.fq.headroom);
    // ... (CQ, RX, TX ring 映射类似)

    // 5. 绑定到网卡队列
    struct sockaddr_xdp addr = {
        .sxdp_family = AF_XDP,
        .sxdp_flags = XDP_COPY,  // COPY 模式（兼容性）
        .sxdp_ifindex = if_nametoindex(ifname),
        .sxdp_queue_id = queue_id,
    };
    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return 1;
    }

    printf("AF_XDP socket 创建成功: %s qid=%d\n", ifname, queue_id);

    // 6. 主循环
    struct pollfd pfd = { .fd = sock, .events = POLLIN };
    uint64_t stats[128] = {0};

    while (running) {
        int ret = poll(&pfd, 1, 1000);
        if (ret < 0) break;
        if (ret == 0) continue;  // timeout

        // 接收数据包
        struct xdp_desc descs[64];
        int n = recvfrom(sock, descs, 64, 0, NULL, NULL);
        if (n <= 0) continue;

        stats[0]++;  // rx count

        for (int i = 0; i < n; i++) {
            void *pkt = umem_base + descs[i].addr;
            // 处理：打印/修改/转发
            // ...
        }
    }

    printf("统计: RX=%lu\n", stats[0]);

    close(sock);
    munmap(umem_base, umem_size);
    return 0;
}
```

### 7.2 编译与运行

```bash
# 编译
gcc -o af_xdp_example af_xdp_example.c -Wall

# 设置大页（必须）
echo 256 | sudo tee /proc/sys/vm/nr_hugepages
mkdir -p /dev/hugepages
mount -t hugetlbfs none /dev/hugepages

# 运行（需要 root）
sudo ./af_xdp_example eth0 0

# 查看 XDP 统计
ip link show eth0
bpftool net show
cat /proc/net/xdp/affinities
```

---

## 8. 小结

```
AF_XDP 架构与原理总结：

核心定位：
  · AF_XDP = XDP + UMEM + Socket
  · 提供内核级别的网络高速路径
  · 零拷贝 + 可编程 + 不独占 NIC

关键组件：
  1. XDP（eXpress Data Path）
     · 最早处理点（DMA 之后，sk_buff 之前）
     · BPF 可编程
     · 四种返回值：PASS / DROP / REDIRECT / TX

  2. UMEM（Unified Memory）
     · 大页内存池
     · 四个 ring：FILL / FQ / RQ / CQ
     · SPSC 无锁设计

  3. AF_XDP Socket
     · 绑定到网卡队列
     · POLL 接收/发送
     · 支持 COPY 和 ZEROCOPY 模式

数据路径：
  RX: NIC → DMA → XDP → UMEM (chunk) → 用户态
  TX: 用户态 → UMEM (chunk) → XDP → NIC DMA → 发送

性能定位：
  · 延迟：5-15us（比 DPDK 略高，比 io_uring 低很多）
  · CPU：低（轮询替代中断）
  · 零拷贝：需要 NIC + 驱动支持

对比：
  · vs DPDK：不需要独占 NIC，可与内核共存
  · vs io_uring：网络专用，极致性能
  · 互补：AF_XDP 网络 + io_uring 存储

系列预告：
  Ch2: XDP 脚本与 BPF 程序
  Ch3: AF_XDP 数据路径分析
  Ch4: AF_XDP vs DPDK vs io_uring 对比
  Ch5: AF_XDP + io_uring 融合架构
  Ch6: 生产环境实战与调优
```

---

## 延伸阅读

- 内核文档: `Documentation/networking/af_xdp.rst`
- XDP 文档: `Documentation/networking/xdp.rst`
- iproute2: `https://git.kernel.org/pub/scm/network/iproute2/iproute2.git`
- libbpf: `https://github.com/libbpf/libbpf`
- XDP 参考仓库: `https://github.com/xdp-project/xdp-tools`
- LWN: "AF_XDP": https://lwn.net/Articles/825070/
- LWN: "XDP for mere mortals": https://lwn.net/Articles/738508/
- Red Hat blog: "XDP (eXpress Data Path)": https://www.redhat.com/en/blog/express-data-path-xdp
- NVIDIA blog: "AF_XDP zero-copy": https://developer.nvidia.com/blog/accelerating-networking-with-af-xdp-zero-copy/