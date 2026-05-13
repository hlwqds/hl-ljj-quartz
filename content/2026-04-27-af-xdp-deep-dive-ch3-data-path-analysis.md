---
title: AF_XDP 深度探索 Ch3：数据路径分析
date: 2026-04-27 09:00:00
tags: [AF_XDP, XDP, Data Path, Zero Copy, UMEM, Ring Buffer, DMA, Packet Flow, Kernel Path, Driver, NAPI, RX, TX, Tracepoints, Performance Analysis, Latency Breakdown]
description: 深入解析 AF_XDP 完整数据路径：NIC DMA → XDP → UMEM → 用户态 → 发送的全流程，tracepoint 追踪，以及各阶段延迟分解。
---

# AF_XDP 深度探索 Ch3：数据路径分析

## 1. 数据路径全景

### 1.1 完整数据包生命周期

```
AF_XDP 完整数据路径：

┌──────────────────────────────────────────────────────────────────────┐
│                        RX（接收）路径                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. NIC 接收数据包                                                   │
│     └── 网卡硬件 DMA 到 DDR 主内存                                   │
│                                                                      │
│  2. NAPI 软中断（内核）                                             │
│     ├── 驱动处理 DMA 完成，分配 skb                                │
│     ├── 触发 NAPI poll（可被 XDP 劫持）                            │
│     └── → XDP 触发点                                                 │
│                                                                      │
│  3. XDP 程序执行                                                    │
│     ├── BPF JIT 编译后 native 执行                                 │
│     ├── 检查 packet header（MAC/IP/Port）                          │
│     └── 返回 XDP_PASS / XDP_DROP / XDP_REDIRECT                    │
│                                                                      │
│  4a. XDP_REDIRECT 到 AF_XDP                                        │
│      ├── 查找目标 socket（通过 xsk_map）                           │
│      ├── 从 socket 的 FILL ring 取空闲 chunk                        │
│      ├── 复制/重映射数据包到 chunk（ZEROCOPY vs COPY）             │
│      ├── 填写 RQ（Receive Queue）ring                              │
│      └── 用户态 poll 感知                                            │
│                                                                      │
│  4b. XDP_PASS（不重定向）                                           │
│      ├── 创建 skb                                                    │
│      └── 走正常网络栈（TCP/IP/iptables）                            │
│                                                                      │
│  5. 用户态接收                                                       │
│      ├── recv() / poll() 返回                                       │
│      ├── 从 RQ 取 chunk 地址                                         │
│      ├── 访问 UMEM 中数据包（用户态直接访问）                      │
│      └── 处理完成后，归还 chunk 到 FILL ring                        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        TX（发送）路径                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 用户态构造数据包                                                 │
│     ├── 写入 UMEM chunk（用户态内存）                              │
│     └── 填写 metadata（目的 MAC/IP/Port）                           │
│                                                                      │
│  2. 提交到 FQ（Fill Queue / Request Queue）                         │
│     ├── 生产者：用户态                                               │
│     └── 消费者：内核网络栈                                          │
│                                                                      │
│  3. 内核处理                                                         │
│     ├── 从 FQ 取 chunk 地址                                         │
│     ├── 构造 skb（或直接 DMA）                                      │
│     └── 调用驱动 TX                                                  │
│                                                                      │
│  4. NIC DMA 发送                                                    │
│     └── 从 UMEM chunk 直接 DMA 到网卡                              │
│                                                                      │
│  5. 完成通知                                                         │
│     ├── TX 完成，进入 CQ（Completion Queue）                        │
│     └── 用户态 poll 感知，归还 chunk 到 FILL ring                   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 1.2 各阶段延迟分解

```
数据包延迟分解（4KB 包）：

┌──────────────────────────────────────────────────────────────────────┐
│  阶段                    │   延迟(us)    │   占比    │  优化空间   │
├──────────────────────────────────────────────────────────────────────┤
│  NIC DMA 接收           │   0.5-1       │   8%      │   硬件决定  │
│  驱动处理                │   0.3-0.5     │   5%      │   硬件决定  │
│  XDP BPF 执行           │   0.1-0.2     │   2%      │   JIT 优化  │
│  XDP → UMEM 拷贝        │   0.2-0.5     │   5%      │   ZEROCOPY  │
│  Ring 通知（中断/polling）│   0.5-1       │   10%      │   busy-poll│
│  用户态处理（应用）      │   1-5         │   40%      │   应用决定  │
│  UMEM → FQ 提交         │   0.1-0.2     │   2%      │   可忽略    │
│  内核 → 驱动 → TX DMA   │   1-2         │   20%      │   硬件决定  │
├──────────────────────────────────────────────────────────────────────┤
│  总计（单向）            │   4-11        │   100%     │            │
│  双向往返（RTT）        │   8-22        │            │            │
└──────────────────────────────────────────────────────────────────────┘

优化关键点：
  1. ZEROCOPY 消除 XDP→UMEM 拷贝（+0.2-0.5us）
  2. busy-polling 消除中断延迟（+0.5-1us）
  3. 减少用户态处理时间（+1-5us）
  4. 绑定 NUMA / 避免跨核（+0.5-1us）
```

---

## 2. 接收路径详解

### 2.1 NIC 到内核（DMA + 驱动）

```
NIC 接收数据包到内核的过程：

  1. NIC 硬件
     ├── 网卡从 wire 接收电信号/光信号
     ├── PHY 完成编码/解码（SFP+ / RJ45）
     ├── MAC 层校验 CRC
     └── DMA 引擎将数据搬运到 DDR（RX ring）

  2. RX Descriptor Ring
     ┌────────────────────────────────────────────────────────────┐
     │  RX Ring（主机内存）                                       │
     │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
     │  │ Desc[0] │ │ Desc[1] │ │ Desc[2] │ │ Desc[3] │ ...   │
     │  │ DMA addr│ │ DMA addr│ │ DMA addr│ │ DMA addr│        │
     │  └──────────┘ └──────────┘ └──────────┘ └──────────┘      │
     │       │                                                       │
     │       ▼ DMA                                                   │
     │  ┌──────────────────────────────────────────────────────┐   │
     │  │              NIC DDR / RX Buffer                     │   │
     │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐              │   │
     │  │  │ Packet  │ │ Packet  │ │ Packet  │   ...        │   │
     │  │  │  4KB    │ │  4KB    │ │  4KB    │              │   │
     │  │  └──────────┘ └──────────┘ └──────────┘              │   │
     │  └──────────────────────────────────────────────────────┘   │
     └────────────────────────────────────────────────────────────┘
     ```

  3. 驱动处理（NAPI 之前）
     ├── 网卡触发 MSI-X 中断
     ├── 驱动注册 NAPI poll 回调
     ├── 禁用后续中断（poll 模式）
     └── 分配 skb（可选，XDP 可能跳过）

### 2.2 XDP 触发点

```
XDP 在 NIC 接收流程中的位置：

  NIC 收到包
      │
      ▼
  DMA 到 RX Ring（主机内存）
      │
      ▼
  ┌─────────────────────────────────────────────────────────────┐
  │              ★★★ XDP 触发点 ★★★                           │
  │  此时 sk_buff 尚未创建！                                   │
  │  XDP 程序可以：                                           │
  │    · 读取 packet header（data 指针）                      │
  │    · 修改 packet content                                   │
  │    · 重定向到 AF_XDP / 其他接口                           │
  │    · 丢弃（DDoS 防护）                                    │
  └─────────────────────────────────────────────────────────────┘
      │
      ├── XDP_DROP → 丢弃（不创建 skb）
      │
      ├── XDP_PASS → 创建 skb → 网络栈
      │
      └── XDP_REDIRECT → 重定向到其他接口/AF_XDP
```

```c
// XDP 处理上下文（ctx）
struct xdp_md {
    __u32 data;      // 数据包起始偏移（相对于UMEM chunk）
    __u32 data_end;  // 数据包结束偏移
    __u32 data_meta; // meta 区域（可选）
    __u32 ingress_ifindex;  // 入接口 index
    __u32 rx_queue_index;  // 队列 index
};

// XDP 程序示例：查看 ctx
SEC("xdp")
int xdp_inspect(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // data 和 data_end 之间就是数据包
    __u32 pkt_size = data_end - data;

    // 入接口
    __u32 ifindex = ctx->ingress_ifindex;

    // 队列号
    __u32 q = ctx->rx_queue_index;

    return XDP_PASS;
}
```

### 2.3 XDP_REDIRECT 到 AF_XDP

```
XDP → AF_XDP 重定向流程：

  1. XDP 程序返回 XDP_REDIRECT
     └── bpf_redirect(map_id, flags)

  2. 内核查找 xsk_map（XDP Socket Map）
     ┌────────────────────────────────────────┐
     │  xsk_map（BPF Map）                    │
     │  key: ifindex + queue_id               │
     │  value: xdp_socket 指针                │
     └────────────────────────────────────────┘

  3. 分配 chunk（从 socket 的 UMEM）
     ├── 从 FILL ring 取空闲 chunk
     ├── 如果 FILL ring 为空 → 分配失败，drop
     └── chunk 地址对齐到 64 字节

  4. 零拷贝 vs 拷贝
     ┌──────────────────────────────────────────────────────────┐
     │  ZEROCOPY 模式（需要 NIC + 驱动支持）：                  │
     │    · NIC DMA 重映射到 UMEM chunk                         │
     │    · 无需拷贝，性能最优                                   │
     │    · 需要 scatter-gather DMA 支持                        │
     │                                                          │
     │  COPY 模式（回退方案）：                                 │
     │    · 数据已在 skb / 临时 buffer                          │
     │    · memcpy 到 UMEM chunk                                │
     │    · 额外 0.2-0.5us 延迟                                 │
     └──────────────────────────────────────────────────────────┘

  5. 填写 RQ（Receive Queue）
     ┌────────────────────────────────────────┐
     │  RQ entry:                             │
     │    · chunk 地址                        │
     │    · packet 长度                       │
     │    · metadata（可选）                  │
     └────────────────────────────────────────┘

  6. 用户态感知
     ├── poll() 返回 POLLIN
     └── recv() 取走数据
```

### 2.4 用户态接收

```c
// af_xdp_rx.c — 用户态接收流程

#include <poll.h>
#include <sys/socket.h>

#define BATCH_SIZE 64

struct xdp_desc {
    __u64 addr;   // UMEM chunk 地址
    __u32 len;    // 包长度
    __u32 options;
};

int rx_loop(int xsk_fd, void *umem_base)
{
    struct pollfd pfd = { .fd = xsk_fd, .events = POLLIN };
    struct xdp_desc desc[BATCH_SIZE];

    while (1) {
        // 1. 等待数据包
        //    - 使用 poll（阻塞）
        //    - 使用 SO_PREFER_BUSY_POLL（busy-polling）
        int ret = poll(&pfd, 1, 1000);
        if (ret < 0) break;
        if (ret == 0) continue;  // timeout

        // 2. 批量接收
        int n = recvfrom(xsk_fd, desc, BATCH_SIZE, 0, NULL, NULL);
        if (n <= 0) continue;

        // 3. 处理每个包
        for (int i = 0; i < n; i++) {
            void *pkt = umem_base + desc[i].addr;
            __u32 len = desc[i].len;

            // 处理数据包
            process_packet(pkt, len);
        }

        // 4. 归还 chunks 到 FILL ring
        //    告诉内核这些 chunk 空闲，可重用
        //    （部分实现自动归还）
    }
}

// 零拷贝接收（ZEROCOPY 模式）
int rx_zero_copy(int xsk_fd, void *umem_base)
{
    // ZEROCOPY 模式下，数据包保持在 UMEM
    // 用户态直接访问，避免 copy

    struct xdp_desc desc;
    int n = recvfrom(xsk_fd, &desc, 1, MSG_ZEROCOPY, NULL, NULL);
    if (n > 0) {
        void *pkt = umem_base + desc.addr;

        // 直接访问，无拷贝
        handle_packet(pkt, desc.len);

        // 内核自动归还 chunk（某些实现需要手动）
        // 或使用 sendto 通知 FILL ring
    }
}
```

---

## 3. 发送路径详解

### 3.1 用户态发送

```c
// af_xdp_tx.c — 用户态发送流程

#include <sys/socket.h>
#include <linux/if_xdp.h>

// 发送单个数据包
int tx_packet(int xsk_fd, void *umem_base, void *pkt_data, __u32 len)
{
    // 1. 找一个空闲 chunk
    //    方案 A：从 FILL ring 取（之前用过的）
    //    方案 B：使用固定 chunk（预分配）

    static __u32 next_chunk = 0;
    __u64 chunk_addr = get_free_chunk();  // 从 free list

    // 2. 拷贝数据到 chunk
    void *chunk = umem_base + chunk_addr;
    memcpy(chunk, pkt_data, len);

    // 3. 构造 xdp_desc
    struct xdp_desc desc = {
        .addr = chunk_addr,
        .len = len,
        .options = 0,
    };

    // 4. 提交到 FQ（Request Queue）
    int ret = sendto(xsk_fd, &desc, 1, 0, NULL, 0);
    if (ret < 0) {
        // 失败，归还 chunk
        return_chunk_to_fill_ring(chunk_addr);
        return -1;
    }

    return 0;
}

// 批量发送
int tx_batch(int xsk_fd, void *umem_base, struct packet *pkts[], int count)
{
    struct xdp_desc descs[256];

    for (int i = 0; i < count; i++) {
        __u64 addr = get_free_chunk();
        void *chunk = umem_base + addr;

        memcpy(chunk, pkts[i]->data, pkts[i]->len);

        descs[i] = (struct xdp_desc){
            .addr = addr,
            .len = pkts[i]->len,
        };
    }

    // 一次 sendto 提交多个
    return sendto(xsk_fd, descs, count, 0, NULL, 0);
}
```

### 3.2 内核处理与 TX DMA

```
发送流程（内核侧）：

  1. 用户态提交到 FQ
     ┌────────────────────────────────────────┐
     │  FQ（Request Queue）                    │
     │  · 用户态 生产                         │
     │  · 内核态 消费                         │
     │  · 无锁 SPSC ring                      │
     └────────────────────────────────────────┘
          │
          │ 内核 poll / 轮询
          ▼
  2. 内核取出 chunk 描述符
     ├── 读取 addr + len
     └── 构造 skb 或直接 DMA

  3. 构造数据包
     ┌──────────────────────────────────────────────────────────┐
     │  方案 A：传统 skb                                        │
     │    · 分配 skb                                            │
     │    · 拷贝 chunk 数据到 skb                              │
     │    · 添加 protocol headers                              │
     │    · 优点：兼容内核协议栈                               │
     │    · 缺点：额外拷贝                                      │
     │                                                          │
     │  方案 B：直接 DMA（ZEROCOPY）                            │
     │    · 不分配 skb                                         │
     │    · 直接从 chunk DMA 发送                              │
     │    · 需要驱动支持（mlx5, ice 等）                       │
     │    · 优点：无拷贝，最优性能                              │
     └──────────────────────────────────────────────────────────┘

  4. 网卡 TX
     ├── TX DMA 引擎从 DDR 读取数据
     ├── 添加 Ethernet FCS
     ├── 编码（Manchester / NRZ / PAM4）
     └── 输出到 PHY

  5. 完成通知
     ├── 网卡触发 TX 完成中断（可选 busy-poll）
     ├── DMA 完成描述符写回
     ├── 进入 CQ（Completion Queue）
     └── 用户态 poll 感知
```

### 3.3 完成与回收

```c
// af_xdp_complete.c — 完成处理与 chunk 回收

// CQ（Completion Queue）处理
int handle_completions(int xsk_fd)
{
    struct pollfd pfd = { .fd = xsk_fd, .events = POLLOUT };
    __u32 completion[BATCH_SIZE];

    // 1. 等待完成事件
    //    POLLOUT = 发送完成
    //    或者主动 poll / busy-poll CQ
    int ret = poll(&pfd, 1, 0);  // 非阻塞

    if (ret > 0) {
        // 2. 读取完成描述符
        //    completion[] 存放已发送 chunk 的索引
        int n = recv(xsk_fd, completion, BATCH_SIZE, MSG_ERRQUEUE);
        //    注意：AF_XDP 的完成通知使用特殊方式

        // 3. 回收 chunks
        for (int i = 0; i < n; i++) {
            __u32 chunk_idx = completion[i];
            return_chunk_to_free_list(chunk_idx);
        }
    }

    return 0;
}

// 完整发送循环
int tx_loop(int xsk_fd, void *umem_base)
{
    while (1) {
        // 发送
        struct packet *pkt = get_next_packet();
        if (pkt) {
            tx_packet(xsk_fd, umem_base, pkt->data, pkt->len);
        }

        // 处理完成
        handle_completions(xsk_fd);

        // 归还接收的 chunks（Rx → FILL ring）
        handle_rx_completions(xsk_fd);
    }
}
```

---

## 4. Ring 机制深度解析

### 4.1 四大 Ring 的职责

```
AF_XDP 四大 Ring：

┌──────────────────────────────────────────────────────────────────────┐
│                        FILL RING（填充环）                          │
├──────────────────────────────────────────────────────────────────────┤
│  方向：内核 → 用户态                                                  │
│  生产者：内核（驱动）                                                │
│  消费者：用户态                                                      │
│  内容：空闲 chunk 地址                                                │
│                                                                      │
│  用途：告诉用户态 "这些 chunks 空闲，可以接收新数据"                 │
│                                                                      │
│  操作：                                                               │
│    · 内核自动填充（驱动收到 RX DMA 完成）                           │
│    · 用户态读取（取出空闲 chunk）                                    │
│    · 归还：recv() 后自动归还，或手动通知                             │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                     RECEIVE (RQ) RING（接收环）                      │
├──────────────────────────────────────────────────────────────────────┤
│  方向：内核 → 用户态                                                  │
│  生产者：内核（XDP 重定向）                                          │
│  消费者：用户态                                                      │
│  内容：xdp_desc（addr + len + options）                              │
│                                                                      │
│  用途：通知用户态 "有数据包到达，在这个 chunk"                       │
│                                                                      │
│  操作：                                                               │
│    · 内核填写（XDP_REDIRECT 成功时）                                │
│    · 用户态 recv() 取走                                             │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                     REQUEST (FQ) RING（请求环）                      │
├──────────────────────────────────────────────────────────────────────┤
│  方向：用户态 → 内核                                                  │
│  生产者：用户态（发送请求）                                          │
│  消费者：内核（发送处理）                                            │
│  内容：xdp_desc（addr + len + options）                              │
│                                                                      │
│  用途：用户态 请求内核帮忙发送数据                                   │
│                                                                      │
│  操作：                                                               │
│    · 用户态 sendto() 填写                                            │
│    · 内核取走处理                                                     │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                    COMPLETION (CQ) RING（完成环）                    │
├──────────────────────────────────────────────────────────────────────┤
│  方向：内核 → 用户态                                                  │
│  生产者：内核（TX 完成）                                             │
│  消费者：用户态                                                      │
│  内容：xdp_desc（addr + len + options）或简单索引                   │
│                                                                      │
│  用途：告诉用户态 "这些包已发送完成，chunk 可重用"                   │
│                                                                      │
│  操作：                                                               │
│    · 内核填写（TX DMA 完成）                                        │
│    · 用户态 poll() / recv(MSG_ERRQUEUE) 取走                       │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.2 Ring 实现（无锁 SPSC）

```c
// Ring Buffer 实现（SPSC：无锁单生产者单消费者）

// 简化实现
struct xsk_ring {
    __u32 cached_prod;  // 生产者本地副本
    __u32 cached_cons;  // 消费者本地副本
    __u32 *producer;
    __u32 *consumer;
    void **desc;         // 描述符数组（chunk 地址）
    __u32 size;          // ring 大小（2^n）
    __u32 mask;          // size - 1（用于取模）
};

// 生产者（内核）
static inline __u32 xsk_prod_acquire(struct xsk_ring *ring)
{
    __u32 prod = ring->cached_prod;

    // 检查可用空间
    // consumer 追踪消费者位置
    if ((prod - *ring->consumer) >= ring->size)
        return 0;  // ring 满

    return prod;
}

// 消费者（用户态）
static inline __u32 xsk_cons_acquire(struct xsk_ring *ring)
{
    __u32 cons = ring->cached_cons;

    // 检查是否有数据
    if (*ring->producer == cons)
        return 0;  // ring 空

    return cons;
}

// 获取 slot（生产者）
static inline void *xsk_prod_get_slot(struct xsk_ring *ring, __u32 idx)
{
    return ring->desc[idx & ring->mask];
}

// 获取 slot（消费者）
static inline void *xsk_cons_get_slot(struct xsk_ring *ring, __u32 idx)
{
    return ring->desc[idx & ring->mask];
}
```

### 4.3 同步机制

```
四大 Ring 的同步方式：

┌──────────────────────────────────────────────────────────────────────┐
│                        同步原语                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. 内存屏障（Memory Barrier）                                        │
│     · 防止指令重排序                                                 │
│     · 确保 desc 写入在 indices 更新之前完成                         │
│     · volatile 或 __sync_synchronize()                             │
│                                                                      │
│  2. Cache Line 避免                                                  │
│     · producer 和 consumer 避免同 cache line                        │
│     · 减少 false sharing                                            │
│     · xdp_mmap_offsets 提供正确偏移                                  │
│                                                                      │
│  3. 忙等 vs 阻塞                                                     │
│     · AF_XDP 默认：poll() 阻塞                                      │
│     · busy-polling：SO_PREFER_BUSY_POLL                            │
│     · SO_BUSY_POLL_BUDGET：轮询次数                                 │
│                                                                      │
│  4. 用户态通知                                                       │
│     · SOL_XDP + XDP_OPTIONS                                         │
│     · SO_BINDTODEVICE：绑定设备                                     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

poll() vs busy-polling 对比：

  poll():
    · 调用内核，等待事件
    · 有额外系统调用开销
    · 延迟：+5-50us（取决于系统负载）

  busy-polling:
    · 用户态轮询 CQ/FQ
    · 无系统调用，低延迟
    · CPU 占用高（100% busy）
    · 适合：超低延迟场景

  建议：
    · 延迟敏感：busy-polling
    · 吞吐优先：poll() + 大批量
    · 混合：先 busy-poll，timeout 后切 poll
```

---

## 5. 零拷贝条件与实现

### 5.1 零拷贝架构

```
AF_XDP 零拷贝架构：

┌──────────────────────────────────────────────────────────────────────┐
│  理想情况（ZEROCOPY）：                                              │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  NIC ──DMA──► UMEM chunk ──直接访问──► 用户态                        │
│                    │                                                  │
│                    └── 无任何拷贝                                    │
│                                                                      │
│  条件：                                                              │
│    1. NIC + 驱动 支持 scatter-gather DMA 重映射                     │
│    2. 驱动实现 ndo_xdp_xmit 或类似接口                              │
│    3. 使用 XDP_ZEROCOPY flag                                        │
│    4. 大页内存（hugepage）                                          │
│                                                                      │
│  支持驱动：mlx5, ice, i40e, ixgbe (新驱动)                         │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  回退情况（COPY）：                                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  NIC ──DMA──► 临时 buffer ──memcpy──► UMEM chunk ──访问──► 用户态   │
│                      │                                                 │
│                      └── 额外一次内存拷贝（+0.2-0.5us）              │
│                                                                      │
│  触发条件：                                                          │
│    · NIC 不支持零拷贝                                                │
│    · XDP_COPY flag（显式回退）                                      │
│    · chunks 不对齐 / 跨 page                                        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 5.2 ZEROCOPY vs COPY 选择

```c
// af_xdp_mode.c — 零拷贝模式选择

#include <linux/if_xdp.h>

int create_xsk(int fd, int ifindex, int queue_id, int zerocopy)
{
    int sock = socket(AF_XDP, SOCK_RAW, 0);

    struct sockaddr_xdp addr = {
        .sxdp_family = AF_XDP,
        .sxdp_flags = zerocopy ? XDP_ZEROCOPY : XDP_COPY,
        .sxdp_ifindex = ifindex,
        .sxdp_queue_id = queue_id,
    };

    bind(sock, (struct sockaddr *)&addr, sizeof(addr));

    return sock;
}

// 运行时检查是否支持零拷贝
int check_zerocopy_support(int sock)
{
    socklen_t len = sizeof(int);
    int zcopy_supported;

    if (getsockopt(sock, SOL_XDP, XDP_ZEROCOPY, &zcopy_supported, &len) == 0)
        return zcopy_supported;

    return 0;
}
```

### 5.3 NUMA 与内存布局

```
NUMA 影响：

  ┌────────────────────────────────────────────────────────────────┐
  │  NUMA Node 0                    │  NUMA Node 1                 │
  │  ┌──────────────────────────┐   │  ┌──────────────────────────┐│
  │  │  CPU 0-7               │   │  │  CPU 8-15               ││
  │  │  DDR 0-63 GB          │   │  │  DDR 64-127 GB         ││
  │  └──────────────────────────┘   │  └──────────────────────────┘│
  │           │                             │                        │
  │           │  PCIe                       │  PCIe                  │
  │           ▼                             ▼                        │
  │  ┌──────────────────────────────────────────────────────────┐ │
  │  │              NIC (可能连接 Node 0 或 Node 1)               │ │
  │  └──────────────────────────────────────────────────────────┘ │
  └────────────────────────────────────────────────────────────────┘

  问题：
    · NIC DMA 到 Node 1 内存，CPU 0 访问 → 跨 NUMA 延迟（+30-50%）
    · AF_XDP UMEM 如果分配错误，延迟大增

  优化：
    · 将 UMEM 分配在 NIC 连接的 NUMA 节点
    · 进程绑定到同 NUMA 节点（sched_setaffinity）
    · 使用 numactl --membind + --cpunodebind

  查看 NUMA：
    $ lstopo
    $ numactl --hardware
    $ cat /proc/self/numa_maps
```

---

## 6. Tracepoints 与性能分析

### 6.1 相关 Tracepoints

```bash
#!/bin/bash
# trace_xdp.sh — XDP tracepoints

echo "=== XDP Tracepoints ==="

# 列出所有 XDP 相关 tracepoints
ls /sys/kernel/debug/tracing/events/xdp/

# 启用 XDP 跟踪
echo 1 > /sys/kernel/debug/tracing/events/xdp/enable

# 查看 XDP redirect trace
cat /sys/kernel/debug/tracing/trace

# 过滤特定网卡
echo 'ifindex==2' > /sys/kernel/debug/tracing/events/xdp/xdp_redirect_filter

# 特定程序
echo 'prog_id==123' > /sys/kernel/debug/tracing/events/xdp/xdp_redirect_filter

# 查看 AF_XDP tracepoints
ls /sys/kernel/debug/tracing/events/xsk/

# 清除
echo 0 > /sys/kernel/debug/tracing/events/xdp/enable
```

```
主要 Tracepoints：

  xdp:xdp_redirect_template — XDP 重定向
    · ifindex: 目标网卡
    · prog_id: 程序 ID
    · act: XDP_PASS/DROP/REDIRECT

  xdp:xdp_redirect_err — 重定向错误
    · err: 错误码
    · ifindex: 目标网卡

  xdp:xdp_exception — XDP 异常
    · act: XDP_ABORTED/UNKNOWN
    · prog_id: 程序 ID

  xsk:xsk_rcv — AF_XDP 接收
    · addr: chunk 地址
    · len: 包长度

  xsk:xsk_tx_complete — AF_XDP 发送完成
    · addr: chunk 地址

  xsk:xsk_poll — AF_XDP poll 触发
    · runtime: poll 耗时
```

### 6.2 perf 统计

```bash
#!/bin/bash
# perf_xdp.sh — perf 分析 XDP 性能

# 1. perf stat 基础统计
perf stat -e xdp:xdp_redirect -e xdp:xdp_exception \
    -a -- sleep 10

# 2. perf record 热路径
perf record -e cycles -e xdp:xdp_redirect -a \
    -g -- ./xdp_app &

# 3. 查看 XDP 程序热点
perf report --symbol-filter=xdp

# 4. bpftool 统计
bpftool prog show
bpftool prog profile <id> cycles instructions

# 5. ethtool 统计
ethtool -S eth0 | grep -E "xdp|redirect|drop"
```

### 6.3 延迟测量

```c
// latency_test.c — 端到端延迟测量

#include <linux/bpf.h>
#include <linux/time.h>
#include <bpf/bpf_helpers.h>

// per-CPU 延迟直方图
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_HISTOGRAM);
    __uint(max_entries, 10000);
    __type(key, __u32);  // bucket index
    __type(value, __u64); // count
} latency_hist SEC(".maps");

// 发送时戳记录
struct {
    __uint(type, BPF_MAP_TYPE_HASH);
    __uint(max_entries, 65536);
    __type(key, __u64);  // sequence number
    __type(value, __u64); // timestamp (ticks)
} tx_ts_map SEC(".maps");

SEC("xdp")
int xdp_latency_test(struct xdp_md *ctx)
{
    void *data = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    // 解析序列号
    __u64 *seq = data;

    if ((void *)(seq + 1) > data_end)
        return XDP_PASS;

    // 记录接收时间
    __u64 now = bpf_ktime_get_ns();

    // 查找发送时戳
    __u64 *tx_ts = bpf_map_lookup_elem(&tx_ts_map, seq);
    if (tx_ts) {
        // 计算延迟
        __u64 latency = now - *tx_ts;

        // 记录到直方图（单位：100ns）
        __u32 bucket = latency / 100;
        if (bucket >= 10000) bucket = 9999;

        __u64 *cnt = bpf_map_lookup_elem(&latency_hist, &bucket);
        if (cnt) __sync_fetch_and_add(cnt, 1);

        // 删除记录
        bpf_map_delete_elem(&tx_ts_map, seq);
    }

    return XDP_PASS;
}
```

---

## 7. 与网络栈的交互

### 7.1 XDP_PASS 后的处理

```
XDP_PASS 后的网络栈路径：

  XDP 程序返回 XDP_PASS
       │
       ▼
  创建 sk_buff
       │
       ├──► netif_receive_skb()
       │         │
       │         ▼
       │    GRO (Generic Receive Offload)
       │         │
       │         ▼
       │    协议层处理
       │    ├── IP (netif_receive_skb → ip_rcv)
       │    │       │
       │    │       ├──► iptables (PREROUTING)
       │    │       │
       │    │       ├──► 路由查找
       │    │       │
       │    │       └──► iptables (FORWARD)
       │    │
       │    ├── TCP (tcp_v4_rcv)
       │    │       │
       │    │       └──► socket queue
       │    │
       │    └── UDP (udp_rcv)
       │            │
       │            └──► socket queue
       │
       └──► 应用 recv() / read()

  与 AF_XDP 的区别：
    XDP_PASS → 走完整网络栈（TCP/IP/iptables）
    XDP_REDIRECT → 跳过大部分网络栈
```

### 7.2 共存：XDP + 内核协议栈

```
多程序共存（TC + XDP）：

  ┌────────────────────────────────────────────────────────────────┐
  │                      Ingress (RX)                              │
  │                                                               │
  │   NIC ──DMA──►                                                       │
  │               │                                                     │
  │               ▼                                                     │
  │         ┌─────────────┐                                         │
  │         │  XDP 程序   │  ←── 最早处理，可 DROP/REDIRECT         │
  │         │  (ifindex)  │                                         │
  │         └──────┬──────┘                                         │
  │                │ XDP_PASS                                        │
  │                ▼                                                     │
  │         ┌─────────────┐                                         │
  │         │  TC (clsact) │  ←── 流量控制，可 MIRROR/POLICE        │
  │         │  ingress     │                                         │
  │         └──────┬──────┘                                         │
  │                │ PASS                                            │
  │                ▼                                                     │
  │         ┌─────────────┐                                         │
  │         │  netfilter  │  ←── iptables/nftables                  │
  │         │  PREROUTING  │                                         │
  │         └──────┬──────┘                                         │
  │                │                                                  │
  │                ▼                                                  │
  │         内核协议栈                                                 │
  └────────────────────────────────────────────────────────────────┘

  处理顺序：XDP → TC → netfilter → 协议栈

  最佳实践：
    · 简单过滤（IP/Port）→ XDP（最快）
    · 复杂匹配 → TC + BPF
    · NAT/防火墙 → nftables（XDP 之后）
```

---

## 8. 常见陷阱与优化

### 8.1 常见性能陷阱

```
AF_XDP 常见性能陷阱：

┌──────────────────────────────────────────────────────────────────────┐
│  陷阱 1: Chunk 耗尽                                                  │
├──────────────────────────────────────────────────────────────────────┤
│  问题：FILL ring 为空，无法接收新数据包                               │
│  症状：大量 drop，recv() 返回 0                                     │
│  解决：                                                                    │
│    · 增加 UMEM chunk 数量                                            │
│    · 确保 recv() 后及时归还 chunks                                   │
│    · 监控 FILL ring 水位                                             │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  陷阱 2: 跨 NUMA 访问                                                │
├──────────────────────────────────────────────────────────────────────┤
│  问题：UMEM 在 Node 0，进程在 Node 1                                │
│  症状：延迟抖动，带宽下降                                            │
│  解决：                                                                    │
│    · numactl --membind=0 --cpunodebind=0                             │
│    · 监控 numastat                                                   │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  陷阱 3: 队列亲和性                                                  │
├──────────────────────────────────────────────────────────────────────┤
│  问题：socket 绑定队列 0，但 RSS 分流到其他队列                      │
│  症状：部分包丢失                                                    │
│  解决：                                                                    │
│    · 关闭 RSS：ethtool -X eth0 equal 1                              │
│    · 或创建多个 socket，每个绑定不同队列                             │
│    · 接收端：SO_REUSEPORT                                            │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  陷阱 4: 小包性能差                                                  │
├──────────────────────────────────────────────────────────────────────┤
│  问题：64B 小包，header 处理开销占比高                               │
│  症状：小包带宽远低于理论值                                          │
│  解决：                                                                    │
│    · 使用 GRO 合并小包                                               │
│    · 批量处理（recv 多个包再统一处理）                               │
│    · 检查 NIC offload（CSUM/TSO）                                   │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│  陷阱 5: 锁竞争                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  问题：多个 socket 共享 FILL ring 或资源                            │
│  症状：多核扩展性差                                                  │
│  解决：                                                                    │
│    · 每个队列独立 socket                                             │
│    · SO_REUSEPORT groups                                            │
│    · 避免共享状态                                                    │
└──────────────────────────────────────────────────────────────────────┘
```

### 8.2 优化清单

```bash
#!/bin/bash
# optimize_xdp.sh — AF_XDP 优化脚本

IFACE="${1:-eth0}"

echo "=== AF_XDP 优化 ==="

# 1. 网卡队列配置
echo "[1] 网卡配置..."
# 关闭 RSS（单队列场景）
ethtool -L ${IFACE} combined 1
# 或设置 RSS 队列数
ethtool -L ${IFACE} combined 8

# 2. 巨型帧
ethtool -G ${IFACE} rx 4096 tx 4096 2>/dev/null || true
ethtool -s ${IFACE} mtu 9000

# 3. 卸载
ethtool -K ${IFACE} rxvlan on 2>/dev/null || true
ethtool -K ${IFACE} txvlan on 2>/dev/null || true
ethtool -K ${IFACE} tso on 2>/dev/null || true
ethtool -K ${IFACE} gso on 2>/dev/null || true

# 4. 中断亲和
echo "[2] 中断亲和..."
for i in $(ls /proc/irq/ | grep -E "eth|mlx"); do
    # 绑定到特定 CPU
    # echo 1 > /proc/irq/$i/smp_affinity_list
    true
done

# 5. 大页
echo "[3] 大页配置..."
echo 256 > /proc/sys/vm/nr_hugepages

# 6. 验证
echo "[4] 验证..."
ethtool -i ${IFACE} | grep driver
ethtool -l ${IFACE}
```

---

## 9. 小结

```
AF_XDP 数据路径分析总结：

完整路径：
  RX: NIC DMA → XDP → UMEM chunk → 用户态 → 归还 FILL
  TX: 用户态 → FQ → 内核 → 驱动 → TX DMA → 完成

四大 Ring：
  FILL → 内核告诉用户态哪些 chunk 空闲
  RQ   → 内核告诉用户态有哪些包到达
  FQ   → 用户态告诉内核要发送哪些包
  CQ   → 内核告诉用户态哪些包已发送

延迟分解：
  单向：4-11us（优化后 4-6us）
  组成：DMA(1us) + XDP(0.2us) + 拷贝(0.3us) + 应用(1-5us)

零拷贝：
  ZEROCOPY：mlx5/ice 驱动，需要 hugepage
  COPY：回退方案，+0.2-0.5us

NUMA 影响：
  跨 NUMA 延迟 +30-50%
  解决：绑定 NUMA + membind

性能陷阱：
  1. Chunk 耗尽 → 增加 UMEM 大小
  2. 跨 NUMA → numactl 绑定
  3. RSS 分流 → 关闭 RSS 或多 socket
  4. 小包差 → GRO + 批量处理
  5. 锁竞争 → per-queue socket

优化手段：
  · ethtool -L rx 1（单队列）
  · busy-polling
  · hugepage
  · numactl 绑定
  · GRO/GSO offload

Tracepoints：
  xdp:xdp_redirect / xdp:xdp_exception
  xsk:xsk_rcv / xsk:xsk_tx_complete

与网络栈共存：
  XDP（最早）→ TC → netfilter → 协议栈
  XDP_REDIRECT 跳过大部分网络栈
  XDP_PASS 走完整路径

系列预告：
  Ch4: AF_XDP vs DPDK vs io_uring 对比
  Ch5: AF_XDP + io_uring 融合架构
  Ch6: 生产环境实战与调优
```

---

## 延伸阅读

- 内核源码: `net/xdp/xsk.c`, `net/xdp/xdp_umem.c`, `net/xdp/xsk_map.c`
- 驱动源码: `drivers/net/ethernet/mellanox/mlx5/core/en/xdp.c`
- XDP tracepoints: `kernel/trace/bpf_trace.c`
- LWN: "XDP redirect to AF_XDP": https://lwn.net/Articles/825071/
- LWN: "AF_XDP implementation": https://lwn.net/Articles/824593/
- lwn: "XDP performance numbers": https://lwn.net/Articles/818挪
- NVIDIA blog: "AF_XDP zero-copy": https://developer.nvidia.com/blog/accelerating-networking-with-af-xdp-zero-copy/
- Intel blog: "Intel E810 and XDP": https://www.intel.com/content/www/us/en/developer/articles/technical/e810-xdp.html