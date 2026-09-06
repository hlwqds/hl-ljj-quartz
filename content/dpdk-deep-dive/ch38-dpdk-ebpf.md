---
title: "DPDK 深度探索 ch38：eBPF/XDP 与 DPDK 协同——从内核快路径到 AF_XDP PMD"
date: 2026-04-09 16:30:00
tags: [dpdk, ebpf, xdp, af_xdp, kernel-bypass, rte-bpf, libbpf, libxdp, cilium]
description: "从 DPDK 工程视角解析 eBPF/XDP/AF_XDP：XDP 三种模式与性能、AF_XDP 零拷贝原理、DPDK AF_XDP PMD 配置、rte_bpf 用户态 BPF、集成模式与选型指南"
---

# DPDK 深度探索 ch38：eBPF/XDP 与 DPDK 协同——从内核快路径到 AF_XDP PMD

> [!info] 章节定位
> DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
>
> 关联章节：
>
> - [[ch30-lookaside-crypto|Lookaside 加速——Cryptodev、QAT、IPsec]]
> - [[ch37-smartnic|SmartNIC 数据面——Representor、E-Switch 与硬件卸载]]

> [!abstract] 核心结论
> eBPF/XDP 和 DPDK 不是替代关系，而是 **分层协同**：
>
> 1. **XDP** 在内核驱动层做最早期包处理（drop/pass/redirect），适合过滤、DDoS 防护和负载均衡；
> 2. **AF_XDP** 通过零拷贝 UMEM 把包送到用户态，介于内核和完全 bypass 之间；
> 3. **DPDK AF_XDP PMD**（`net_af_xdp`）让 DPDK 应用通过 AF_XDP 收发包，无需独占网卡；
> 4. **DPDK rte_bpf** 在 DPDK 应用内部嵌入 BPF VM，实现应用内的可编程处理钩子；
> 5. 选型不取决于"谁更快"，而是 **能否独占网卡、是否需要内核协议栈、部署灵活性和运维复杂度**。

---

## 1. eBPF 与 DPDK 的定位差异

### 1.1 为什么需要两个数据面

DPDK 通过内核 bypass 达到极致性能，但 bypass 本身带来代价：

```text
DPDK 的代价：
  · 独占网卡（其他进程、内核协议栈都不能用）
  · 需要 hugepages、VFIO、root 权限
  · 与内核网络工具（iptables、tcpdump、路由）不兼容
  · 运维复杂——必须自己实现 ARP、邻居、路由

eBPF/XDP 的代价：
  · 仍在内核路径中，受内核调度和锁影响
  · 验证器限制程序复杂度（循环、指令数、栈大小）
  · 不能完全自定义协议栈行为
  · 性能上限低于 DPDK

问题来了：能不能两者都用？
```

答案是 **分层**：

```text
                     性能
                      ▲
                      │
          DPDK ◀─────│────── 完全 bypass，最高吞吐
                      │
        AF_XDP ◀─────│────── 零拷贝到用户态，不独占网卡
                      │
           XDP ◀─────│────── 内核驱动层，最早介入点
                      │
      内核协议栈 ◀───│────── 标准路径
                      │
                      └────────────────────▶ 灵活性
```

### 1.2 eBPF vs DPDK 速查

| 维度       | eBPF/XDP                           | DPDK                                |
| ---------- | ---------------------------------- | ----------------------------------- |
| 运行位置   | 内核（或硬件 offload）             | 用户态                              |
| 权限需求   | CAP_BPF / CAP_NET_ADMIN            | root + hugepages + VFIO             |
| 网卡独占   | 不独占，与内核协议栈共存           | 通常独占                            |
| 可编程性   | 受验证器限制（指令数、无任意循环） | 完全自由（C/Rust/任何语言）         |
| 包处理路径 | DMA → 驱动 → XDP → 内核            | DMA → 用户态                        |
| 内核协议栈 | 可共存（XDP_PASS 回内核）          | 完全绕过                            |
| 部署门槛   | 低（加载 BPF 程序即可）            | 高（hugepages、驱动绑定、专用配置） |
| 热更新     | 原子替换 BPF 程序                  | 需要重启应用                        |
| 典型吞吐   | 10-20 Mpps（native XDP）           | 30-100+ Mpps                        |
| 典型场景   | 过滤、LB、DDoS 防护、可观测性      | 网关、NFV、高性能转发               |

---

## 2. XDP：内核最早介入点

### 2.1 XDP 在收包路径中的位置

```text
Packet arrives at NIC
        │
        ▼
  ┌───────────────────┐
  │   NIC Driver      │
  │   DMA to memory   │
  └─────────┬─────────┘
            │
            ▼
  ┌───────────────────┐
  │   XDP Hook        │  ← eBPF 程序在这里执行
  │   (before skb     │     还没有分配 sk_buff
  │    allocation)    │     这是整个内核路径中最早的位置
  └─────────┬─────────┘
            │
      ┌─────┼──────┬───────────┐
      │     │      │           │
      ▼     ▼      ▼           ▼
    DROP  PASS  TX(return)  REDIRECT
                    │           │
                    │      ┌────┴────┐
                    │      │         │
                    │   AF_XDP   another NIC
                    │   socket   (DEVMAP)
                    ▼
              ┌───────────┐
              │  sk_buff   │
              │  alloc     │
              └─────┬─────┘
                    │
                    ▼
              内核协议栈
```

### 2.2 XDP 三种运行模式

| 模式        | 挂载位置            | 性能 | 兼容性     | 说明                           |
| ----------- | ------------------- | ---- | ---------- | ------------------------------ |
| **Native**  | NIC 驱动层          | 最高 | 需驱动支持 | 在 skb 分配前执行，零额外开销  |
| **Generic** | `netif_receive_skb` | 较低 | 所有 NIC   | 在 skb 分配后执行，有额外开销  |
| **Offload** | NIC 硬件            | 线速 | 特定 NIC   | 程序卸载到网卡（如 Netronome） |

检查当前模式：

```bash
# 查看 XDP 程序是否挂载
ip link show dev eth0
# 输出中包含 "xdp" 字段表示已挂载

# 查看 XDP 模式（generic 显示 "xdpgeneric"）
ip -d link show dev eth0

# ethtool 查看 XDP 能力
ethtool -k eth0 | grep -i xdp
# hw-xdp: on/off  （硬件是否支持 native XDP）
```

```bash
# 挂载 XDP 程序（指定模式）
ip link set dev eth0 xdpgeneric obj prog.o sec xdp    # generic 模式
ip link set dev eth0 xdp obj prog.o sec xdp            # native 模式（默认）
ip link set dev eth0 xdpoffload obj prog.o sec xdp     # offload 模式

# 卸载
ip link set dev eth0 xdp off
```

> [!warning] Generic 模式的性能陷阱
> Generic XDP 在 skb 分配之后执行，绕过了 XDP 最大的性能优势（避免 skb 开销）。
> 在生产环境中应使用 native 模式或 offload 模式。如果驱动不支持 native XDP，
> generic 模式的性能可能不如预期，此时应考虑 DPDK 或 AF_XDP。

### 2.3 XDP 动作与 Map 类型

XDP 程序返回的动作：

```c
enum xdp_action {
    XDP_ABORTED   = 0,  // 错误，包被丢弃，计入统计
    XDP_DROP      = 1,  // 静默丢弃——DDoS 防护最常用
    XDP_PASS      = 2,  // 交给内核协议栈继续处理
    XDP_TX        = 3,  // 从同一网卡发回（源 MAC → 目的 MAC 交换后）
    XDP_REDIRECT  = 4,  // 重定向到其他目标（AF_XDP socket / 其他网卡 / 其他 CPU）
};
```

XDP 重定向相关的 Map 类型：

| Map 类型                   | 用途                                  | 配合动作           |
| -------------------------- | ------------------------------------- | ------------------ |
| `BPF_MAP_TYPE_XSKMAP`      | 重定向到 AF_XDP socket                | `bpf_redirect_map` |
| `BPF_MAP_TYPE_DEVMAP`      | 重定向到其他网卡（XDP_TX 的增强版）   | `bpf_redirect_map` |
| `BPF_MAP_TYPE_CPUMAP`      | 重定向到其他 CPU 处理（跨核负载均衡） | `bpf_redirect_map` |
| `BPF_MAP_TYPE_DEVMAP_HASH` | Hash 版 DEVMAP，支持动态网卡管理      | `bpf_redirect_map` |

### 2.4 XDP 程序示例：基于 XSKMAP 的包过滤

```c
// xdp_sock.bpf.c
// 将特定端口的 TCP 包重定向到 AF_XDP socket，其余交给内核
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>

/* AF_XDP socket map：每个队列一个 socket */
struct {
    __uint(type, BPF_MAP_TYPE_XSKMAP);
    __uint(max_entries, 64);
    __type(key, __u32);       /* queue index */
    __type(value, __u32);     /* fd */
} xsk_map SEC(".maps");

SEC("xdp")
int xdp_sock_prog(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    /* 解析 Ethernet */
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != __builtin_bswap16(0x0800)) /* ETH_P_IP */
        return XDP_PASS;

    /* 解析 IPv4 */
    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    /* 只处理 TCP */
    if (iph->protocol != 6) /* IPPROTO_TCP */
        return XDP_PASS;

    /* 解析 TCP */
    struct tcphdr *th = (void *)iph + (iph->ihl * 4);
    if ((void *)(th + 1) > data_end)
        return XDP_PASS;

    /* 只将目标端口 80/443 的流量重定向到 AF_XDP */
    __u16 dst_port = __builtin_bswap16(th->dest);
    if (dst_port == 80 || dst_port == 443) {
        /* 根据 RX 队列索引查找对应的 AF_XDP socket */
        return bpf_redirect_map(&xsk_map, ctx->rx_queue_index, 0);
    }

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
```

### 2.5 编译和加载

```bash
# 编译 XDP 程序
clang -O2 -g -Wall -target bpf \
    -c xdp_sock.bpf.c -o xdp_sock.bpf.o

# 使用 bpftool 查看 BPF 程序和 map
bpftool prog show
bpftool map show

# 加载到网卡（需要 libxdp 时用 xdp-loader）
xdp-loader load -m native eth0 xdp_sock.bpf.o

# 或使用 ip（不经过 libxdp）
ip link set dev eth0 xdp obj xdp_sock.bpf.o sec xdp

# 查看 XDP 统计
ip -s link show dev eth0
bpftool prog show xdp
```

---

## 3. AF_XDP：零拷贝到用户态

### 3.1 AF_XDP 在数据路径中的位置

```text
传统内核收包：
  NIC → DMA → skb → netif_receive_skb → ip_rcv → tcp_v4_rcv → socket → App
                     (分配 skb)     (协议栈处理)         (拷贝到用户态)

XDP + AF_XDP（零拷贝）：
  NIC → DMA → XDP → bpf_redirect_map(XSKMAP)
                          │
                          ▼
                    UMEM（用户态共享内存）
                          │
                    ┌─────┴─────┐
                    │ Fill Queue │  App → Kernel：请填入这些地址
                    │ RX Queue   │  Kernel → App：收到的包在这里
                    │ TX Queue   │  App → Kernel：请发送这些包
                    │ Comp Queue │  Kernel → App：发送完成的包
                    └───────────┘
                          │
                          ▼
                      用户态 App

关键：零拷贝模式下，包数据始终在 UMEM 中，不经过 skb 和用户态拷贝。
```

### 3.2 UMEM 与四条 Ring

```text
┌───────────────────────────────────────────────────────────┐
│                        UMEM                               │
│  用户态 mmap 分配的连续内存，被划分为等大的 chunk          │
│                                                           │
│  ┌──────────┬──────────┬──────────┬──────────┬─────────┐ │
│  │ Chunk 0  │ Chunk 1  │ Chunk 2  │ Chunk 3  │  ...    │ │
│  │ (2K/4K)  │ (2K/4K)  │ (2K/4K)  │ (2K/4K)  │         │ │
│  └──────────┴──────────┴──────────┴──────────┴─────────┘ │
└───────────────────────────────────────────────────────────┘

四条 Ring Buffer（Single Producer / Single Consumer）：

  Fill Queue (App → Kernel)        Completion Queue (Kernel → App)
  ┌───┬───┬───┬───┬───┐           ┌───┬───┬───┬───┬───┐
  │addr│addr│addr│   │   │           │addr│addr│   │   │   │
  └───┴───┴───┴───┴───┘           └───┴───┴───┴───┴───┘
  App 填入 chunk 地址，             Kernel 返回已发送完的
  请求 Kernel 把收到的              chunk 地址，App 可以
  包放入这些 chunk                  复用这些 chunk

  RX Queue (Kernel → App)          TX Queue (App → Kernel)
  ┌───────┬───────┬───┐           ┌───────┬───┬───┐
  │desc(0)│desc(1)│   │           │desc(0)│   │   │
  └───────┴───────┴───┘           └───────┴───┴───┘
  Kernel 收到包后写入               App 填入要发送的包
  desc = (addr, len)               desc = (addr, len)
```

核心概念：

| 概念                 | 说明                                                   |
| -------------------- | ------------------------------------------------------ |
| **UMEM**             | 用户态共享内存区域，存放 packet 数据                   |
| **Chunk**            | UMEM 中的固定大小块（2K 或 4K），每个 chunk 存一个包   |
| **Fill Queue**       | App 把空闲 chunk 地址告诉 Kernel，"请往这里放收到的包" |
| **Completion Queue** | Kernel 把已用完的 chunk 地址还回 App（TX 完成后）      |
| **RX Queue**         | Kernel 把收到的包的描述符（addr + len）告诉 App        |
| **TX Queue**         | App 把要发送的包的描述符告诉 Kernel                    |

### 3.3 零拷贝 vs 拷贝模式

| 维度        | 零拷贝（zero-copy）             | 拷贝（copy）              |
| ----------- | ------------------------------- | ------------------------- |
| 数据移动    | 包直接在 UMEM 中，无拷贝        | Kernel 从 skb 拷贝到 UMEM |
| 性能        | 高（省掉 memcpy）               | 较低（额外一次拷贝）      |
| 驱动要求    | NIC 驱动必须支持 zero-copy      | 所有支持 XDP 的驱动都支持 |
| MTU 限制    | 最大 MTU ≈ page_size（通常 4K） | 无特殊限制                |
| Chunk 大小  | 必须 2K 或 4K，页对齐           | 更灵活                    |
| Kernel 版本 | 5.4+                            | 4.18+                     |

> [!info] 如何判断是否在用零拷贝
>
> ```bash
> # 查看 AF_XDP socket 统计
> cat /proc/net/xdp/stats
> # 如果 "zc"（zero-copy）计数在增长，说明在用零拷贝
> # 如果 "copy" 计数在增长，说明在用拷贝模式
>
> # 或者在代码中检查 bind_flags
> # XDP_ZEROCOPY = 零拷贝
> # XDP_COPY = 强制拷贝
> # 0 = 自动选择（优先零拷贝，驱动不支持则降级为拷贝）
> ```

### 3.4 XDP_SHARED_UMEM

多个 AF_XDP socket（不同队列或不同网卡）可以共享同一个 UMEM：

```text
                    ┌─────────────────┐
                    │      UMEM       │
                    └────────┬────────┘
                             │ shared
              ┌──────────────┼──────────────┐
              │              │              │
        ┌─────┴─────┐  ┌────┴──────┐  ┌────┴──────┐
        │ Socket 0  │  │ Socket 1  │  │ Socket 2  │
        │ Queue 0   │  │ Queue 1   │  │ Queue 2   │
        └───────────┘  └───────────┘  └───────────┘

好处：所有队列的包在同一个内存池中，应用不需要为每个队列分配独立内存。
```

绑定共享 UMEM 的关键代码：

```c
/* 第一个 socket：创建 UMEM 并绑定 */
struct sockaddr_xdp sxdp = {
    .sxdp_family = PF_XDP,
    .sxdp_ifindex = if_nametoindex("eth0"),
    .sxdp_queue_id = 0,
    .sxdp_flags = XDP_ZEROCOPY,
};

/* 后续 socket：共享第一个 socket 的 UMEM */
struct sockaddr_xdp sxdp_shared = {
    .sxdp_family = PF_XDP,
    .sxdp_ifindex = if_nametoindex("eth0"),
    .sxdp_queue_id = 1,
    .sxdp_flags = XDP_SHARED_UMEM | XDP_ZEROCOPY,
    .sxdp_shared_umem_id = /* 第一个 socket 的 umem ID */,
};
```

---

## 4. DPDK AF_XDP PMD：通过 AF_XDP 使用 DPDK

### 4.1 为什么需要 AF_XDP PMD

DPDK 通常需要独占网卡（绑定到 VFIO），但这在很多场景下不可行：

- 云环境/容器中无法绑定 VFIO
- 需要同时使用内核协议栈和 DPDK
- 不想处理 hugepages 和驱动绑定的运维负担
- 渐进式迁移：先通过 AF_XDP 跑 DPDK 应用，再迁移到 VFIO

DPDK 的 `net_af_xdp` PMD 让 DPDK 应用通过 AF_XDP socket 收发包，
**使用标准 DPDK API（rte_eth_rx_burst / rte_eth_tx_burst）**，底层走 AF_XDP。

### 4.2 配置方式

```bash
# 基本配置：绑定到 eth0 的 queue 0
dpdk-testpmd -l 0-1 --no-pci -- \
    --vdev net_af_xdp,iface=eth0 \
    -- -i

# 指定队列范围
dpdk-testpmd -l 0-3 --no-pci -- \
    --vdev net_af_xdp,iface=eth0,start_queue=0,queue_count=4 \
    -- -i

# 强制拷贝模式（当零拷贝不工作时调试用）
dpdk-testpmd -l 0-1 --no-pci -- \
    --vdev net_af_xdp,iface=eth0,force_copy=1 \
    -- -i

# 使用自定义 XDP 程序（替换默认的 libbpf/libxdp 程序）
dpdk-testpmd -l 0-1 --no-pci -- \
    --vdev net_af_xdp,iface=eth0,xdp_prog=/path/to/custom_xdp.o \
    -- -i

# 自定义 UMEM chunk 数量和大小
dpdk-testpmd -l 0-1 --no-pci -- \
    --vdev net_af_xdp,iface=eth0,xdp_umem_chunk_size=4096 \
    -- -i
```

devargs 参数：

| 参数                  | 默认值 | 说明                            |
| --------------------- | ------ | ------------------------------- |
| `iface`               | 必填   | 网卡接口名（如 `eth0`）         |
| `start_queue`         | 0      | 起始 RX 队列编号                |
| `queue_count`         | 1      | 使用的队列数量                  |
| `force_copy`          | 0      | 强制拷贝模式（禁用零拷贝）      |
| `xdp_prog`            | 内置   | 自定义 XDP 程序路径             |
| `xdp_umem_chunk_size` | 4096   | UMEM chunk 大小（2048 或 4096） |
| `busy_budget`         | 64     | 内核 busy-poll 每次处理的包数   |
| `use_cni`             | 0      | 使用 CNI（容器网络接口）模式    |

### 4.3 工作原理

```text
DPDK 应用
  │
  │ rte_eth_rx_burst() / rte_eth_tx_burst()
  │ （标准 DPDK ethdev API）
  ▼
┌─────────────────────────┐
│  AF_XDP PMD (net_af_xdp) │
│                         │
│  · 管理 UMEM            │
│  · 管理 Fill/Comp/RX/TX │
│  · mbuf ↔ UMEM chunk 映射│
│  · zero-copy: external mbuf│
│  · copy: memcpy 到 mbuf  │
└────────────┬────────────┘
             │ AF_XDP socket
             ▼
┌─────────────────────────┐
│  Kernel (XDP + AF_XDP)  │
│  · XDP 程序挂载在网卡上 │
│  · bpf_redirect_map →   │
│    AF_XDP socket         │
└────────────┬────────────┘
             │
             ▼
          NIC (eth0)
```

> [!info] `--no-pci` 的含义
> 使用 AF_XDP PMD 时不绑定 PCI 设备（网卡由内核驱动管理），
> 所以需要 `--no-pci` 参数。DPDK 通过 AF_XDP socket 访问网卡，
> 不需要 VFIO 绑定。

### 4.4 局限性

| 局限                    | 说明                                           |
| ----------------------- | ---------------------------------------------- |
| MTU 限制                | 零拷贝模式下 MTU 不超过 page_size（通常 4K）   |
| 性能低于 VFIO DPDK      | 仍经过内核 XDP 路径，比直接 VFIO 多几微秒延迟  |
| Chunk 大小              | 仅支持 2K 或 4K                                |
| 内核版本依赖            | 零拷贝需要 5.4+，部分特性需要更新内核          |
| 多进程不支持            | 同一队列不能被多个 DPDK 进程同时使用           |
| 无硬件 checksum offload | 依赖内核和驱动的 offload 能力                  |
| 优先级低于 VFIO         | 当同一网卡同时有 VFIO 和 AF_XDP PMD 时可能冲突 |

### 4.5 使用 AF_XDP PMD 的典型场景

```text
场景 1：容器中运行 DPDK 应用
─────────────────────────────
  · 容器没有 VFIO 访问权限
  · 通过 AF_XDP PMD 共享宿主机网卡
  · 不影响其他容器和宿主机的网络

场景 2：渐进式迁移到 DPDK
─────────────────────────
  · 先用 AF_XDP PMD 跑 DPDK 应用，验证逻辑
  · 性能满足就保持；不满足再切到 VFIO

场景 3：同时需要内核协议栈和 DPDK
─────────────────────────────────
  · 部分队列走 AF_XDP PMD（DPDK 处理）
  · 部分队列走内核协议栈（SSH、管理、监控）

场景 4：DPDK 应用需要访问内核路由表
───────────────────────────────────
  · AF_XDP 模式下内核协议栈正常工作
  · 应用可以利用内核的路由、ARP、邻居表
```

---

## 5. DPDK rte_bpf：应用内的 BPF 虚拟机

### 5.1 rte_bpf 是什么

DPDK 自带了一个用户态 eBPF 虚拟机（`rte_bpf`），可以在 DPDK 应用内部
加载和执行 BPF 程序。这不是内核 eBPF，而是 **应用级的可编程钩子**。

```text
内核 eBPF：
  App → bpf() syscall → Kernel verifier → JIT → Kernel 执行

DPDK rte_bpf：
  App → rte_bpf_load() → DPDK JIT → App 内执行
  （不经过内核，在用户态运行）
```

### 5.2 核心 API

```c
#include <rte_bpf.h>
#include <rte_bpf_ethdev.h>

/*
 * BPF 程序的输入参数。
 * mbuf 指针和 mbuf 指针的指针。
 */
struct rte_bpf_prm {
    /* BPF 程序的入口参数类型定义 */
    const struct rte_bpf_arg *prog_arg;
    /* 指令数组 */
    const struct ebpf_insn *ins;
    uint32_t nb_ins;
    /* 外部符号表（BPF 程序可以调用外部函数） */
    const struct rte_bpf_xsym *xsym;
    uint32_t nb_xsym;
};

/* 从 ELF 文件加载 BPF 程序 */
struct rte_bpf *
rte_bpf_elf_load(const struct rte_bpf_prm *prm,
                 const char *fname, const char *sname);

/* 从指令数组加载 */
struct rte_bpf *
rte_bpf_load(const struct rte_bpf_prm *prm);

/* 执行 BPF 程序 */
uint64_t
rte_bpf_exec(const struct rte_bpf *bpf, void *ctx);

/* 批量执行（对每个 mbuf 执行一次） */
uint32_t
rte_bpf_exec_burst(const struct rte_bpf *bpf,
                   void *ctxs[], uint64_t rc[], uint32_t num);

/* 在 ethdev RX/TX 路径上挂载 BPF 钩子 */
int
rte_bpf_eth_rx_elf_load(uint16_t port, uint16_t queue,
                         const struct rte_bpf_prm *prm,
                         const char *fname, const char *sname,
                         uint32_t flags);

int
rte_bpf_eth_tx_elf_load(uint16_t port, uint16_t queue,
                         const struct rte_bpf_prm *prm,
                         const char *fname, const char *sname,
                         uint32_t flags);
```

### 5.3 使用场景

```text
应用场景：
  · 在 RX 路径上做自定义过滤（不需要重新编译应用）
  · 动态加载统计/采样逻辑
  · 不修改核心转发逻辑的情况下增加临时调试钩子
  · 允许用户/运维通过 BPF 程序自定义处理逻辑

限制：
  · 不是内核 eBPF——不能访问内核数据结构
  · 没有 BPF Map（需要自行与主应用通信）
  · 没有 tail call（不能链接多个 BPF 程序）
  · 验证器比内核简单
  · 不适合复杂包处理（指令数有限）
```

### 5.4 rte_bpf 示例：RX 路径过滤

```c
/*
 * 在 port 0, queue 0 的 RX 路径上挂载一个 BPF 程序。
 * BPF 程序接收 rte_mbuf * 作为输入，返回 0 或 1。
 * 返回 0 = 丢弃，返回 1 = 保留。
 *
 * BPF 程序可以编译为 ELF 文件后用 rte_bpf_elf_load 加载，
 * 也可以直接用 rte_bpf_eth_rx_elf_load 挂载到指定队列。
 */

/* 方法 1：直接挂载 ELF 文件到 RX 路径 */
int rc = rte_bpf_eth_rx_elf_load(
    0,              /* port_id */
    0,              /* queue_id */
    &prm,           /* BPF 参数 */
    "filter.o",     /* ELF 文件 */
    "filter",       /* 符号名 */
    0               /* flags */
);

if (rc < 0) {
    /* BPF 程序加载失败：检查指令合法性、符号是否存在 */
    fprintf(stderr, "Failed to load BPF: %s\n", strerror(-rc));
}

/* 方法 2：手动执行 */
struct rte_bpf *bpf = rte_bpf_elf_load(&prm, "filter.o", "filter");

struct rte_mbuf *pkts[BURST_SIZE];
uint16_t n = rte_eth_rx_burst(port, queue, pkts, BURST_SIZE);

void *ctxs[BURST_SIZE];
uint64_t rc_vals[BURST_SIZE];
for (int i = 0; i < n; i++)
    ctxs[i] = pkts[i];

/* 批量执行 BPF 过滤 */
rte_bpf_exec_burst(bpf, ctxs, rc_vals, n);

/* rc_vals[i] == 0 表示丢弃 */
int j = 0;
for (int i = 0; i < n; i++) {
    if (rc_vals[i] != 0)
        pkts[j++] = pkts[i];
    else
        rte_pktmbuf_free(pkts[i]);
}
/* j = 保留的包数 */
```

---

## 6. 集成模式与选型

### 6.1 三种协同架构

```text
架构 A：XDP 前置过滤 + DPDK 数据面
═══════════════════════════════════════

  NIC → XDP（drop/DDoS 防护/简单过滤）
         │
         ├─ XDP_DROP（大部分流量在内核层就丢了）
         └─ XDP_PASS → 内核 → AF_XDP → DPDK 应用
                         或
                      XDP_REDIRECT → AF_XDP socket → DPDK AF_XDP PMD

  适用：需要先过滤再处理的高吞吐场景
  例如：DDoS 防护、WAF 前置


架构 B：纯 AF_XDP PMD（不独占网卡）
═══════════════════════════════════════

  NIC → 内核驱动 → AF_XDP → DPDK AF_XDP PMD → 应用
         │
         └─ 其他流量走正常内核路径

  适用：容器、云环境、不能独占网卡
  例如：K8s 中的 DPDK 应用、开发/测试


架构 C：纯 DPDK（VFIO 独占）
══════════════════════════════

  NIC → VFIO → DPDK 应用（完全 bypass）

  适用：最高性能、独占网卡可行
  例如：NFV 网关、高性能 LB、电信级转发
```

### 6.2 选型决策

```text
能否独占网卡？
    │
    ├── Yes ──→ 需要极致性能（>20Mpps）？
    │               │
    │               ├── Yes ──→ DPDK VFIO（架构 C）
    │               └── No  ──→ 考虑 AF_XDP PMD（架构 B）
    │                            门槛更低，性能够用
    │
    └── No ──→ 需要内核协议栈共存？
                    │
                    ├── Yes ──→ AF_XDP PMD（架构 B）
                    │            内核协议栈正常工作
                    │
                    └── No ──→ 只需要过滤/简单处理？
                                  │
                                  ├── Yes ──→ 纯 XDP（内核层处理）
                                  └── No  ──→ AF_XDP PMD + rte_bpf
                                               自定义处理逻辑
```

### 6.3 性能参考

以下数据基于公开基准测试，实际性能取决于硬件、内核版本和负载特征：

| 方案                  | 典型吞吐（单核） | 延迟 | CPU 效率 | 部署复杂度 |
| --------------------- | ---------------- | ---- | -------- | ---------- |
| DPDK (VFIO)           | 30-80+ Mpps      | 最低 | 最高     | 高         |
| AF_XDP PMD (零拷贝)   | 15-25 Mpps       | 中低 | 中高     | 中         |
| AF_XDP PMD (拷贝)     | 8-15 Mpps        | 中   | 中       | 中         |
| XDP Native (DROP)     | 20-40 Mpps       | 最低 | 高       | 低         |
| XDP Native (redirect) | 15-30 Mpps       | 低   | 中高     | 低         |
| XDP Generic           | 3-8 Mpps         | 中高 | 中低     | 最低       |
| libpcap               | 0.5-1 Mpps       | 高   | 低       | 最低       |

> [!warning] AF_XDP PMD 的性能不是 DPDK VFIO 的替代
> AF_XDP PMD 的性能约为 VFIO DPDK 的 50-70%。如果你的场景需要 >30 Mpps，
> AF_XDP PMD 可能不够。AF_XDP PMD 的价值在于 **降低部署门槛**，而不是替代 VFIO。

---

## 7. 实战：XDP 负载均衡器

### 7.1 XDP 负载均衡架构

```text
Client → NIC → XDP LB Program
                    │
                    ├─ 查 conntrack map（已有连接）
                    │   └─ 命中 → 直接转发到对应 backend
                    │
                    ├─ 新连接 → hash 选择 backend
                    │   └─ 写入 conntrack map
                    │
                    ├─ XDP_TX（改写 MAC/IP，从同一网卡发回）
                    │
                    └─ 或 XDP_REDIRECT → DEVMAP → 另一块网卡
```

### 7.2 XDP LB 程序

```c
// xdp_lb.bpf.c
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define MAX_BACKENDS 64
#define MAX_CONNTRACK 65536

/* backend 列表 */
struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, MAX_BACKENDS);
    __type(key, __u32);          /* backend index */
    __type(value, __be32);       /* backend IP */
} backends SEC(".maps");

/* 连接跟踪表 */
struct conn_key {
    __be32 src_ip;
    __be32 dst_ip;
    __be16 src_port;
    __be16 dst_port;
};

struct conn_val {
    __u32 backend_idx;
    __be32 backend_ip;
};

struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, MAX_CONNTRACK);
    __type(key, struct conn_key);
    __type(value, struct conn_val);
} conntrack SEC(".maps");

/* 统计 */
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 3);
    __type(key, __u32);
    __type(value, __u64);
} stats SEC(".maps");

enum {
    STAT_TOTAL = 0,
    STAT_REDIRECTED = 1,
    STAT_DROPPED = 2,
};

SEC("xdp")
int xdp_lb(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    /* 更新总包数 */
    __u32 key = STAT_TOTAL;
    __u64 *val = bpf_map_lookup_elem(&stats, &key);
    if (val)
        __sync_fetch_and_add(val, 1);

    /* 解析 Ethernet */
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_PASS;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    /* 解析 IPv4 */
    struct iphdr *iph = (void *)(eth + 1);
    if ((void *)(iph + 1) > data_end)
        return XDP_PASS;

    if (iph->protocol != IPPROTO_TCP)
        return XDP_PASS;

    /* 解析 TCP */
    struct tcphdr *th = (void *)iph + (iph->ihl * 4);
    if ((void *)(th + 1) > data_end)
        return XDP_PASS;

    /* 构造连接 key */
    struct conn_key ck = {
        .src_ip   = iph->saddr,
        .dst_ip   = iph->daddr,
        .src_port = th->source,
        .dst_port = th->dest,
    };

    /* 查找已有连接 */
    struct conn_val *cv = bpf_map_lookup_elem(&conntrack, &ck);
    __be32 backend_ip;

    if (cv) {
        backend_ip = cv->backend_ip;
    } else {
        /* 新连接：简单 hash 选择 backend */
        __u32 hash = ck.src_ip ^ ck.dst_ip ^ ck.src_port ^ ck.dst_port;
        __u32 idx = hash % MAX_BACKENDS;

        __be32 *bip = bpf_map_lookup_elem(&backends, &idx);
        if (!bip)
            return XDP_DROP;

        backend_ip = *bip;

        /* 写入 conntrack */
        struct conn_val new_cv = {
            .backend_idx = idx,
            .backend_ip = backend_ip,
        };
        bpf_map_update_elem(&conntrack, &ck, &new_cv, BPF_ANY);
    }

    /* 改写目的 IP（简化版，实际需要更新 checksum） */
    /* 注意：XDP_TX 要求修改 MAC 地址，这里省略 MAC 改写 */
    iph->daddr = backend_ip;

    /* 更新 IP checksum（增量更新） */
    /* 实际实现需要正确的 checksum 差量计算 */

    key = STAT_REDIRECTED;
    val = bpf_map_lookup_elem(&stats, &key);
    if (val)
        __sync_fetch_and_add(val, 1);

    return XDP_TX;
}

char _license[] SEC("license") = "GPL";
```

> [!warning] 这个示例是教学用途
> 生产级 XDP LB 还需要处理：
>
> - **MAC 地址改写**（XDP_TX 时需要修改以太网头）
> - **IP checksum 正确更新**（增量 checksum 计算或重新计算）
> - **连接老化**（conntrack 表的 LRU 或超时清理）
> - **健康检查**（backend 不可用时从列表移除）
> - **TCP MSS clamping**（避免 MTU 问题）
>
> Cilium、Katran（Facebook）、Maglev（Google）等生产级 LB 可以参考。

### 7.3 与 DPDK 的协同

```bash
# 场景：XDP 做第一层 LB → AF_XDP PMD 做深度处理
#
# 1. 加载 XDP 程序（过滤 + redirect 到 AF_XDP socket）
ip link set dev eth0 xdp obj xdp_lb.bpf.o sec xdp

# 2. DPDK 应用通过 AF_XDP PMD 接收被 redirect 的包
dpdk-l2fwd -l 0-1 --no-pci -- \
    --vdev net_af_xdp,iface=eth0,start_queue=0,queue_count=1

# 3. 查看 XDP 和 AF_XDP 统计
ip -s link show dev eth0
bpftool map dump name stats
```

---

## 8. 常见问题与排障

| 现象                               | 可能原因                                  | 排查方向                                           |
| ---------------------------------- | ----------------------------------------- | -------------------------------------------------- |
| AF_XDP PMD 收不到包                | XDP 程序没有正确 redirect 到 socket       | `bpftool prog show`、`bpftool map dump`            |
| 零拷贝不生效                       | NIC 驱动不支持 native XDP 零拷贝          | `ethtool -k eth0 \| grep xdp`、换用 `force_copy=1` |
| AF_XDP PMD 性能低                  | generic XDP 模式、NUMA 不对齐、burst 太小 | 确认 native 模式、检查 NUMA、调大 burst            |
| XDP 程序加载失败（verifier error） | 程序太复杂、无限循环、越界访问            | 简化逻辑、用 `bpf_trace_printk` 调试               |
| DPDK 和内核协议栈冲突              | AF_XDP 占用了所有队列                     | 减少 `queue_count`，留部分队列给内核               |
| MTU 超限丢包                       | 零拷贝模式下包超过 page_size              | 降低 MTU 或改用拷贝模式                            |
| `bpf_redirect_map` 返回无效        | XSKMAP 中没有对应 queue 的 socket         | 检查 socket 创建和 map 更新逻辑                    |
| rte_bpf 加载失败                   | 指令不合法、外部符号未定义                | 检查 BPF 指令、确认 xsym 注册                      |
| 多队列 AF_XDP 性能不如预期         | Fill Queue 竞争、UMEM 未共享              | 使用 `XDP_SHARED_UMEM`、每队列独立 Fill Queue      |
| Cilium 环境中 AF_XDP PMD 工作异常  | Cilium 已经挂载了自己的 XDP 程序          | 使用 `xdp_prog` 参数指定与 Cilium 兼容的程序       |

---

## 9. 总结

```text
eBPF/XDP + DPDK 的核心模型：

内核层（eBPF/XDP）：              用户态（DPDK）：
  · 最早介入点                      · 完全控制数据面
  · 过滤 / drop / redirect          · 自定义协议栈
  · 低部署门槛                      · 最高性能
  · 验证器限制复杂度                · 独占网卡
         │                                │
         └──── AF_XDP 零拷贝 ────────────┘
              连接内核和用户态的桥梁
```

关键要点：

1. **XDP 是内核最快路径**，适合过滤、DDoS 防护和简单 LB，但受验证器限制
2. **AF_XDP 是桥梁**，通过零拷贝把包从内核送到用户态，无需独占网卡
3. **DPDK AF_XDP PMD** 让 DPDK 应用通过 AF_XDP 收发包，用标准 DPDK API，
   适合容器和云环境
4. **DPDK rte_bpf** 在应用内部嵌入 BPF VM，适合动态过滤和调试钩子
5. **选型看约束**：能否独占网卡、是否需要内核协议栈、性能要求和部署复杂度
6. **分层使用**：XDP 前置过滤 + AF_XDP PMD 数据面，是无需独占网卡场景的最优解

> **最重要的问题不是"DPDK 和 eBPF 谁更好"，而是"我的部署约束允许哪种方案，性能差距是否值得额外的运维复杂度"。**

---

## 参考资料

### Linux 内核

- [XDP (eXpress Data Path)](https://www.kernel.org/doc/html/latest/networking/xdp.html)
- [AF_XDP Kernel Documentation](https://www.kernel.org/doc/html/latest/networking/af_xdp.html)
- [BPF Documentation](https://www.kernel.org/doc/html/latest/bpf/index.html)
- [BPF and XDP Reference Guide (Cilium)](https://docs.cilium.io/en/latest/bpf/)

### DPDK

- [DPDK AF_XDP PMD](https://doc.dpdk.org/guides-26.03/nics/af_xdp.html)
- [DPDK rte_bpf Library](https://doc.dpdk.org/guides-26.03/prog_guide/bpf_lib.html)
- [DPDK BPF Ethdev Helper](https://doc.dpdk.org/guides-26.03/prog_guide/bpf_lib.html#bpf-ethdev-helper)

### 工具与库

- [libbpf](https://github.com/libbpf/libbpf) — BPF 加载库
- [libxdp](https://github.com/xdp-project/xdp-tools) — AF_XDP 高层抽象（libbpf 之上）
- [bpftool](https://github.com/libbpf/bpftool) — BPF 程序和 map 管理
- [Cilium](https://cilium.io/) — 基于 eBPF 的云原生网络方案
