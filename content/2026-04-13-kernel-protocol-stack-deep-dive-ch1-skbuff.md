---
title: "Kernel Protocol Stack 深度探索 (一)：sk_buff 与数据包生命周期"
date: 2026-04-13
tags: [linux, kernel, networking, series, sk_buff, netdevice, memory]
description: "从真实 Linux 6.x 数据模型理解 sk_buff：线性区与页片段、headroom/tailroom、引用计数、clone/COW、GRO/GSO、checksum、page_pool、RX/TX 生命周期和可观测方法"
---

> [!info] Kernel Protocol Stack 深度探索系列
>
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|Linux 内核网络栈自顶向下总图]]
> 1. **第一章：sk_buff 与数据包生命周期**
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]
>
> 本文以 Linux 6.x 为主线。`struct sk_buff` 会随内核版本、架构和配置变化，
> 不应依赖网上抄来的固定字段顺序或结构体大小。

---

## 1. sk_buff 到底是什么

`struct sk_buff`，简称 `skb`，是 Linux 网络栈描述一个数据包或一批聚合数据的核心对象。
它不是“装着整个包的结构体”，而是一个**数据描述符**：

```text
sk_buff descriptor
  ├─ packet length and protocol metadata
  ├─ queue/list linkage
  ├─ socket, device and route ownership
  ├─ header offsets
  ├─ checksum/GSO/VLAN/hash metadata
  └─ pointers to packet storage
       ├─ linear head buffer
       ├─ page frags[]
       └─ optional frag_list
```

协议栈处理数据包时，大部分操作是在修改 `skb` 的元数据、偏移和引用关系，
并不意味着每经过一层协议都复制一次完整报文。

### 1.1 skb 在网络栈中的位置

```text
RX:
NIC DMA
  → driver/XDP
  → build skb
  → GRO
  → L2/IP/TCP/UDP
  → socket receive queue
  → recvmsg()

TX:
sendmsg()
  → socket/TCP/UDP
  → build or append skb
  → IP/neighbor
  → qdisc
  → driver DMA mapping
  → TX completion
  → free/recycle skb
```

需要注意：

- native XDP 通常运行在创建 `skb` 之前；
- AF_XDP zero-copy 可以绕过普通 `skb` 主路径；
- 硬件 flow offload 也可能让某些包不进入 host `skb` 路径；
- 普通 socket `recvmsg()` 最终通常仍要把数据复制到用户缓冲区。

所以 `skb` 是 Linux 内核协议栈的核心对象，但不是所有 Linux 网络 I/O 的唯一表示。

---

## 2. 三层内存模型

理解 `skb` 最重要的是区分三个对象：

```text
1. struct sk_buff
   元数据描述符，由 slab cache 分配

2. linear head buffer
   headroom + linear data + tailroom

3. skb_shared_info
   位于 head buffer 末端，保存 dataref、GSO 和 frags[]
```

概念布局如下：

```text
struct sk_buff
┌────────────────────────────────────────────────────────────┐
│ len / data_len / truesize / protocol / ip_summed           │
│ dev / sk / dst / hash / mark / priority                    │
│ mac_header / network_header / transport_header             │
│ head / data / tail / end                                   │
└───────────────┬────────────────────────────────────────────┘
                │
                ▼
linear head buffer
┌───────────────┬────────────────────────┬────────────────────┐
│   headroom    │      linear data       │      tailroom      │
└───────────────┴────────────────────────┴────────────────────┘
^               ^                        ^                    ^
head            data                     tail                 end
                                                             │
                                                             ▼
                                                   skb_shared_info
                                             ┌────────────────────┐
                                             │ dataref            │
                                             │ gso_size/type/segs │
                                             │ nr_frags           │
                                             │ frags[]            │
                                             │ frag_list          │
                                             └────────────────────┘
```

在部分内核配置中，`tail` 和 `end` 存储为相对 `head` 的 offset，而不是裸指针。
应用内核 helper 即可，不应直接假设它们的底层表示。

### 2.1 四个边界

| 边界   | 含义                                     |
| ------ | ---------------------------------------- |
| `head` | 线性缓冲区起点                           |
| `data` | 当前协议层可见数据起点                   |
| `tail` | 线性有效数据结束位置                     |
| `end`  | 线性缓冲区末端，后面是 `skb_shared_info` |

由此得到：

```text
headroom = data - head
linear length = tail - data
tailroom = end - tail
```

内核中应使用 helper：

```c
skb_headroom(skb);
skb_headlen(skb);
skb_tailroom(skb);
```

### 2.2 `len`、`data_len` 和 `truesize`

这三个字段经常被混淆：

```text
skb->len
  整个 skb 的逻辑数据长度

skb->data_len
  非线性数据长度，即 page frags 和 frag_list 中的数据

skb_headlen(skb)
  线性数据长度，通常等于 len - data_len

skb->truesize
  用于 socket/协议栈内存记账的成本，不等于 len，也不保证等于精确物理占用
```

例如：

```text
linear headers + payload: 256 B
page frags:              4096 B

len       = 4352
data_len  = 4096
headlen   = 256
truesize  = allocation/accounting dependent
```

判断是否非线性：

```c
if (skb_is_nonlinear(skb))
    /* 不能假定所有数据都位于 skb->data 后的连续空间 */
```

---

## 3. 头部不是指针，而是相对偏移

现代 `skb` 通常保存：

```c
mac_header;
network_header;
transport_header;

inner_mac_header;
inner_network_header;
inner_transport_header;
```

这些字段表示相对 `head` 的 offset。访问时使用：

```c
struct ethhdr *eth = eth_hdr(skb);
struct iphdr *iph = ip_hdr(skb);
struct tcphdr *th = tcp_hdr(skb);
```

其核心语义类似：

```c
skb_network_header(skb) == skb->head + skb->network_header;
```

不是：

```c
/* 错误心智模型 */
skb->data + skb->mac_header;
```

### 3.1 为什么使用 offset

- `skb_push()`、`skb_pull()` 会移动 `data`；
- clone 可能共享同一个 head buffer；
- tunnel 同时需要 outer 和 inner header；
- 某些架构希望压缩指针大小；
- head buffer 扩展后可以统一重定位。

### 3.2 解析前必须确认数据可访问

以下代码并不总是安全：

```c
struct tcphdr *th = tcp_hdr(skb);
```

因为传输层头部可能不在线性区域内，或者当前层尚未设置 offset。处理不可信包时应先确保：

```c
if (!pskb_may_pull(skb, required_len))
    goto drop;
```

需要读取跨越多个 fragment 的数据时，可使用：

```c
skb_copy_bits(skb, offset, dst, len);
```

只有确实要求连续数据的模块才应考虑：

```c
if (skb_linearize(skb))
    goto drop;
```

`skb_linearize()` 可能分配并复制大量数据，不应成为热路径上的默认操作。

---

## 4. headroom、tailroom 与四个基础操作

Linux 通过移动 `data` 和 `tail` 高效添加或删除协议头。

### 4.1 `skb_reserve()`

在空 skb 上预留头部空间：

```c
struct sk_buff *skb = alloc_skb(payload_len + headroom, GFP_ATOMIC);
if (!skb)
    return -ENOMEM;

skb_reserve(skb, headroom);
```

结果：

```text
before:
head=data=tail

after skb_reserve(64):
head ── 64-byte headroom ── data=tail
```

它只移动 `data` 和 `tail`，不增加 `len`。通常只应在空 skb 初始化阶段使用。

### 4.2 `skb_put()`

向尾部追加数据：

```c
void *payload = skb_put(skb, len);
memcpy(payload, src, len);
```

它移动 `tail` 并增加 `len`。调用者必须保证 tailroom 足够。

### 4.3 `skb_push()`

在当前数据前添加协议头：

```c
struct ethhdr *eth = skb_push(skb, ETH_HLEN);
```

它向 `head` 方向移动 `data` 并增加 `len`。调用者必须保证 headroom 足够且头部可写。

### 4.4 `skb_pull()`

消费当前协议头：

```c
if (!pskb_may_pull(skb, sizeof(struct iphdr)))
    goto drop;

skb_pull(skb, ip_hdr_len);
```

它向 `tail` 方向移动 `data` 并减少 `len`，不释放底层内存。

### 4.5 操作速查

```text
                 data                         tail
                  │                            │
head ─ headroom ──┼──── visible data ──────────┼─ tailroom ─ end

skb_push(n):       data 向左，len 增加
skb_pull(n):       data 向右，len 减少
skb_put(n):        tail 向右，len 增加
skb_trim(n):       缩短到指定长度
skb_reserve(n):    空 skb 的 data/tail 同时向右
```

这些 helper 在启用调试配置时可能检查越界，但生产代码不能依赖调试检查代替长度验证。

---

## 5. 两套引用计数

`skb` 有两种不同的共享关系。

### 5.1 `users`：共享同一个描述符

`skb_get()` 增加 `skb->users`：

```text
caller A ─┐
          ├─ same struct sk_buff
caller B ─┘
```

这表示多个持有者引用**同一个 skb 描述符**。最后一个引用释放后，描述符才销毁。

现代内核中 `users` 是 `refcount_t`，不应描述成普通 `atomic_t`。

### 5.2 `dataref`：多个描述符共享数据区

`skb_clone()` 创建新的 `struct sk_buff`，但共享原来的 head buffer：

```text
skb A descriptor ─┐
                  ├─ shared head/data/frags
skb B descriptor ─┘

A.users = 1
B.users = 1
shared_info.dataref = 2
```

因此：

- 修改 `skb->mark`、`skb->dev` 等描述符元数据通常不会改变另一个 clone；
- 修改共享 packet bytes 前必须确认数据区可写；
- clone 不是“`users` 变成 2”，而是新描述符加共享数据引用。

### 5.3 TCP 的 payload-only clone

`skb_shared_info.dataref` 被分成两部分：

- 低位统计总数据引用；
- 高位统计 payload-only 引用。

TCP 可以保留 payload skb 用于重传，同时把 clone 交给下层添加 L3/L2 头。
`nohdr`、`hdr_len` 和 `skb_header_cloned()` 用于判断头部是否仍可修改。

这是传输层内部优化，不应被普通模块当作通用共享协议。

---

## 6. clone、copy 和 Copy-on-Write

### 6.1 常用 API 的区别

| API                 | 新 skb 描述符 | 共享线性数据 | 共享 page frags | 典型用途                     |
| ------------------- | ------------- | ------------ | --------------- | ---------------------------- |
| `skb_get()`         | 否            | 是           | 是              | 增加同一 skb 的持有引用      |
| `skb_clone()`       | 是            | 是           | 是              | 多播、镜像、重传发送 clone   |
| `skb_copy()`        | 是            | 否           | 否              | 需要完整独立副本             |
| `pskb_copy()`       | 是            | 复制线性区   | 通常共享 frags  | 只需独立线性头部             |
| `skb_copy_expand()` | 是            | 否           | 否              | 完整复制并调整 head/tailroom |

不要把“分片”当成 `skb_copy()` 的同义词。复制、scatter-gather、IP fragmentation
和 GSO segmentation 是四个不同概念。

### 6.2 为什么 clone 后不能直接改包

```c
struct sk_buff *clone = skb_clone(skb, GFP_ATOMIC);
if (!clone)
    return -ENOMEM;

/* 直接修改 clone->data 可能同时影响原 skb */
```

如果只需要添加或修改头部，常用：

```c
if (skb_cow_head(skb, required_headroom))
    goto drop;

/* 此时 head 可写，并具有足够 headroom */
```

如果需要确保整个数据区独占，可根据调用语义使用 `skb_unshare()`、`skb_copy()`
或其他合适 helper。

### 6.3 `pskb_expand_head()`

它可以：

- 增加 headroom；
- 增加 tailroom；
- 在数据被 clone 时建立私有 head；
- 更新相关引用和 offset。

但它可能分配和复制，失败时返回错误。因此任何封装代码都必须处理失败：

```c
if (skb_cow_head(skb, LL_RESERVED_SPACE(dev) + tunnel_hlen))
    goto drop;

hdr = skb_push(skb, tunnel_hlen);
```

不能只检查 headroom，而忽略“是否共享、是否可写”。

---

## 7. 线性区、frags 与 frag_list

### 7.1 `frags[]`

`skb_shared_info.frags[]` 是 page-backed scatter-gather 数组：

```text
linear area:
  Ethernet/IP/TCP headers + small payload

frags[0]:
  page + offset + size

frags[1]:
  page + offset + size
```

常见来源：

- RX driver 将 page_pool page 挂到 skb；
- sendfile/splice 等路径引用 page cache；
- TCP 发送路径把用户页或内核页组织成 SG；
- GRO 合并数据时保留 page fragments。

`nr_frags` 表示有效数组元素数量。最大数量由内核配置和架构决定，不应写死为 17。

### 7.2 `frag_list`

`frag_list` 是额外的 skb 链：

```text
parent skb
  └─ frag_list → child skb → child skb → ...
```

它和 `frags[]` 不同：

- `frags[]` 的元素是 page fragment；
- `frag_list` 的元素是完整 `struct sk_buff`。

某些 GRO、fragmentation 和协议路径会使用 `frag_list`。驱动是否能直接发送这种 skb，
取决于 feature capability；否则需要软件分段或线性化。

### 7.3 SG、IP 分片和 GSO 不同

| 概念               | 解决的问题                | 结果                         |
| ------------------ | ------------------------- | ---------------------------- |
| scatter-gather     | 一个逻辑包分散在多块内存  | 仍是一个网络包               |
| IPv4 fragmentation | 网络 MTU 小于 IP datagram | 多个 IP fragment             |
| GSO                | 延迟软件分段              | 一个大 skb，稍后成为多个包   |
| TSO                | NIC 执行 TCP segmentation | 大 skb 交给硬件切包          |
| GRO                | RX 软件合并同流报文       | 多个输入包形成较大 skb       |
| LRO                | NIC/驱动硬件式接收合并    | 合并发生得更早，语义限制更强 |

---

## 8. GSO/GRO 元数据

大 skb 并不一定对应线上一个巨型报文。

### 8.1 TX GSO

`skb_shared_info` 保存：

```text
gso_size:
  每个输出 segment 的 payload 大小，例如 TCP MSS

gso_segs:
  预计 segment 数，某些路径可能未预先填充

gso_type:
  TCPv4/TCPv6/UDP tunnel 等分段类型
```

发送路径：

```text
TCP produces large skb
  → qdisc sees one skb
  → device supports matching TSO/GSO feature?
       ├─ yes: driver maps SG, NIC segments
       └─ no: skb_gso_segment() software segmentation
```

因此：

- qdisc 的 packet 视角不一定等于线上 packet 数；
- BQL、字节记账和硬件 completion 需要正确处理 GSO；
- 抓包点不同，看到的大包/小包形态也可能不同。

### 8.2 RX GRO

GRO 在 NAPI 上下文中尝试合并兼容报文：

```text
driver NAPI poll
  → napi_gro_receive()
  → protocol GRO callbacks
  → merge / hold / flush / normal
  → protocol stack
```

GRO 的收益主要来自减少：

- 每包协议栈函数调用；
- route/Netfilter/TCP 处理次数；
- skb 元数据和队列操作；
- cache 与 softirq 压力。

它不是无条件“减少延迟”。聚合、flush 时机和大 skb 后续处理可能改变延迟分布，
应以业务 p99/p99.9 测量。

---

## 9. Checksum 状态

`skb->ip_summed` 描述 checksum 已完成到什么程度，而不是一个简单的真假值。

| 状态                   | 常见方向 | 含义                                                   |
| ---------------------- | -------- | ------------------------------------------------------ |
| `CHECKSUM_NONE`        | RX/TX    | 没有可用的硬件校验结果，需要软件处理                   |
| `CHECKSUM_UNNECESSARY` | RX       | 已由硬件或更早层验证，无需再次验证                     |
| `CHECKSUM_COMPLETE`    | RX       | `skb->csum` 带有可供协议栈继续验证的完整 checksum 信息 |
| `CHECKSUM_PARTIAL`     | TX       | 从 `csum_start` 开始，由硬件或后续层补完 checksum      |

TX partial checksum 常见布局：

```text
skb->csum_start
  指向需要计算 checksum 的 L4 数据起点

skb->csum_offset
  checksum 字段相对 csum_start 的位置
```

驱动必须根据 `skb` 元数据设置正确的 descriptor offload 位。如果设备不支持，
网络核心会在合适位置执行软件 checksum。

隧道会进一步引入 inner/outer checksum 和 `csum_level`。不能仅凭
“网卡开启 rx-checksumming”就断言所有协议和隧道都已校验。

---

## 10. 分配、构建和内存记账

### 10.1 常见创建方式

| API/模式                           | 典型场景                     |
| ---------------------------------- | ---------------------------- |
| `alloc_skb()`                      | 通用分配                     |
| `netdev_alloc_skb*()`              | netdevice RX 辅助分配        |
| `napi_alloc_skb()`                 | NAPI RX 路径的小型线性 skb   |
| `build_skb()` / `napi_build_skb()` | 用已有数据缓冲区构建 skb     |
| `napi_get_frags()`                 | NAPI fragment-based GRO 路径 |

不要根据 API 名字推断固定布局。驱动可能：

- copybreak：小包复制到紧凑线性 skb；
- 大包保留在 page fragment；
- 使用 `build_skb()` 让 head 本身来自 page；
- 使用 multi-buffer RX/XDP fragments。

### 10.2 `GFP_KERNEL` 与 `GFP_ATOMIC`

- 可以睡眠的进程上下文通常可使用 `GFP_KERNEL`；
- hardirq、softirq、NAPI 或持有不可睡眠锁时通常需要原子分配语义；
- 驱动应优先使用为其上下文设计的 NAPI/page_pool helper，而不是到处手写
  `alloc_skb(..., GFP_ATOMIC)`。

分配 flag 错误可能导致 sleeping-in-atomic 警告；过度使用 `GFP_ATOMIC`
则会增加保留内存压力和失败概率。

### 10.3 `truesize` 与 socket memory

socket 记账不能只看 payload：

```text
payload bytes
  + skb descriptor
  + head allocation
  + page fragment accounting
  + allocator alignment/overhead
  ≈ skb->truesize based accounting
```

因此接收 1 MB 应用数据可能消耗超过 1 MB socket memory。GRO、分片大小和 page sharing
都会影响记账。

常见 owner helper：

```c
skb_set_owner_w(skb, sk); /* write memory accounting */
skb_set_owner_r(skb, sk); /* receive memory accounting */
```

它们还会设置 destructor，使 skb 销毁时归还 socket 内存。不能随意复制
`skb->sk` 和 `destructor`。

---

## 11. page_pool：回收 DMA page，不是用户态零拷贝

page_pool 为高速 RX 驱动提供每队列/每 NAPI 的 page 或 netmem 分配与回收机制。

```text
page_pool allocation
  → DMA-mapped RX buffer
  → NIC writes packet
  → driver/XDP
  → skb references page
  → protocol stack consumes skb
  → final page reference released
  → recycle to page_pool
  → reuse for another RX descriptor
```

它主要减少：

- page allocator 开销；
- DMA map/unmap；
- 跨 CPU 回收成本；
- cache 和 IOMMU 压力。

### 11.1 常见参数

Linux 6.x 的 `page_pool_params` 包括：

- `order`：分配页阶；
- `pool_size`：ring 容量；
- `nid`：NUMA 节点；
- `dev`：DMA device；
- `napi`：单一消费 NAPI，若不适用则为空；
- `dma_dir`；
- `max_len` / `offset`；
- `netdev` / `queue_idx`；
- `PP_FLAG_DMA_MAP`、`PP_FLAG_DMA_SYNC_DEV` 等 flag。

具体字段会演进，驱动应按目标内核 API 编写。

### 11.2 `pp_recycle`

`skb->pp_recycle` 表示其数据适合在释放时回收到 page_pool，而不是走普通 page free。
回收成立还依赖：

- page 的引用关系；
- DMA 同步状态；
- NUMA 和执行上下文；
- page 是否仍被其他 skb、XDP frame 或用户引用。

page_pool 不等于“`recv()` 不复制”。普通 socket 收包时，page_pool page 仍位于内核，
应用读取通常会发生 copy-to-user。

---

## 12. RX 生命周期

现代驱动的典型接收路径：

```text
1. refill
   driver gets page/netmem from page_pool
   → puts DMA address into RX descriptor

2. DMA
   NIC writes frame into RX buffer
   → marks descriptor complete

3. interrupt moderation
   MSI-X handler acknowledges/masks queue interrupt
   → schedules NAPI

4. NAPI poll
   driver reads completed descriptors
   → DMA sync if required
   → runs XDP

5. build skb
   copybreak / build_skb / attach frags
   → set protocol, hash, VLAN, checksum metadata

6. GRO
   napi_gro_receive()
   → merge or pass normally

7. protocol stack
   netif_receive_skb path
   → L2 / IP / TCP / UDP
   → socket receive queue

8. consume
   recvmsg copies data or a special API references pages
   → skb freed
   → page returned to page_pool when safe
```

### 12.1 驱动必须正确填写的元数据

至少可能包括：

- `skb->dev`；
- `skb->protocol`，常由 `eth_type_trans()` 设置；
- RX queue / `napi_id`；
- RSS hash 与 L4 hash 类型；
- VLAN tag；
- checksum state；
- hardware timestamp；
- packet type；
- page_pool recycle 信息。

元数据填错不会总是立刻崩溃，常表现为：

- RSS/RPS 分布异常；
- checksum error；
- VLAN 丢失；
- GRO 无法合并；
- 抓包内容与实际转发不一致；
- page 泄漏或错误回收。

---

## 13. TX 生命周期与软中断

典型发送路径：

```text
1. process context
   sendmsg()
   → TCP/UDP builds or appends skb

2. protocol output
   route / Netfilter / neighbor
   → skb gets device, headers and offload metadata

3. qdisc
   dev_queue_xmit()
   → TC egress
   → enqueue
   → usually tries to dequeue immediately

4. driver
   ndo_start_xmit()
   → map linear area and frags for DMA
   → fill TX descriptors
   → ring doorbell

5. hardware
   NIC reads descriptors and packet data
   → transmits frames
   → writes TX completion

6. completion
   IRQ schedules NAPI or another driver mechanism
   → clean TX descriptors
   → DMA unmap
   → consume/free skb
   → wake stopped TX queue if space recovered
```

### 13.1 `dev_queue_xmit()` 不会固定等待一批包

每个待发送 skb 通常都会进入 `dev_queue_xmit()`。qdisc 在条件允许时可在当前发送进程
上下文立即 dequeue 并调用驱动。

以下情况可能延迟到后续调度：

- qdisc pacing/整形时间未到；
- qdisc 正被其他 CPU 运行；
- 本轮 quota 用尽；
- netdev TX queue stopped；
- 驱动暂时无法接收更多 descriptor。

后续 qdisc 运行可以由 `NET_TX_SOFTIRQ` 推进。因此它是延迟调度机制，
不是每个 TX skb 的必经批处理阶段。

### 13.2 TX completion 为什么常在 `NET_RX_SOFTIRQ`

很多驱动让同一个 NAPI poll 同时执行：

```c
static int driver_poll(struct napi_struct *napi, int budget)
{
    bool tx_complete = clean_tx_ring(...);
    int rx_done = clean_rx_ring(..., budget);

    /* 根据 TX 是否清完、RX budget 是否耗尽决定是否 complete NAPI */
    ...
}
```

NAPI 由 `NET_RX_SOFTIRQ` 驱动，所以清理 TX completion 也可能运行在
`NET_RX_SOFTIRQ` 上下文。

这里不是软中断“发现 RX 后顺便清 TX”，而是：

```text
TX or RX queue event
  → driver schedules NAPI
  → NET_RX_SOFTIRQ executes registered poll()
  → driver poll decides which TX/RX rings need work
```

这不是所有驱动的强制规定。TX 可以拥有独立 NAPI/vector，也可由 threaded NAPI、
专用 IRQ 或其他轮询机制处理。

---

## 14. 队列、所有权和 `skb->cb`

`skb` 可以挂在：

- `sk_buff_head` 双向队列；
- TCP write/retransmit/out-of-order queue；
- qdisc；
- device backlog；
- fragment reassembly tree；
- GRO list；
- socket receive/error queue。

### 14.1 队列通常拥有 skb

把 skb 交给某个消费型 API 后，调用者通常不能再访问它：

```c
dev_queue_xmit(skb);
/* 无论返回值如何，都不能继续解引用 skb，除非 API 明确说明所有权未转移 */
```

内核网络代码中最危险的错误之一是 use-after-free，其根源通常是没有确认 API 的
consume/borrow/clone 语义。

### 14.2 `cb[48]` 是逐层复用的控制区

`skb->cb` 是一个小型 control buffer，当前拥有 skb 的协议层可以存放私有状态。
不同层会把它解释为不同结构：

```c
struct my_skb_cb {
    u32 flow_id;
    u16 flags;
};

#define MY_SKB_CB(skb) ((struct my_skb_cb *)((skb)->cb))
```

约束：

- 大小不能超过 `skb->cb`；
- 注意对齐；
- 不能假设跨协议层后内容仍保留；
- clone/copy 行为必须结合具体 API 检查；
- 不要把长期对象指针塞进去而不管理生命周期。

---

## 15. 释放语义与 drop reason

### 15.1 `consume_skb()` 与 drop

正常消费和丢包应区分：

```c
consume_skb(skb);       /* 正常完成生命周期 */
kfree_skb_reason(skb, reason); /* 带原因的丢弃 */
```

实际内核还有批量释放、NAPI consume、defer-free 等 helper。应使用当前上下文对应的 API，
而不是所有地方都机械调用 `kfree_skb()`。

最终释放通常包括：

```text
decrement skb users
  → run destructor / release socket accounting
  → release dst, extensions and ancillary state
  → release linear data and page frags
  → recycle page_pool pages when eligible
  → free skb descriptor to slab cache
```

### 15.2 Drop reason

现代内核用 `enum skb_drop_reason` 提供更具体的丢包原因，例如：

- `NO_SOCKET`；
- `SOCKET_RCVBUFF`；
- `TCP_CSUM` / `UDP_CSUM`；
- `NETFILTER_DROP`；
- `IP_RPFILTER`；
- `QDISC_DROP`；
- `CPU_BACKLOG`；
- `XDP`；
- `TC_INGRESS` / `TC_EGRESS`；
- `FULL_RING`；
- `NOMEM`。

原因集合随内核演进。观测程序应读取目标内核 BTF/tracepoint 定义，不要固化数字枚举。

---

## 16. 性能问题应该看什么

### 16.1 分配与回收

关注：

- `skbuff_head_cache` 分配热点；
- page_pool fast/slow allocation；
- 跨 NUMA page；
- DMA map/unmap；
- clone/COW 频率；
- linearize 和 expand 次数；
- socket memory pressure。

### 16.2 数据移动

真正昂贵的往往不是 `struct sk_buff` 本身，而是：

- copy-from-user / copy-to-user；
- header rewrite 导致 COW；
- 非线性 skb 被迫 linearize；
- cache line 在 CPU 间迁移；
- page fragment 跨 NUMA；
- IOMMU/DMA 同步；
- GRO/GSO 形态与设备 capability 不匹配。

### 16.3 批处理边界

```text
RX:
interrupt moderation
  → NAPI budget
  → GRO aggregation
  → socket dequeue

TX:
TCP write coalescing
  → GSO
  → qdisc dequeue quota/pacing
  → driver descriptor batching
  → TX completion cleanup
```

“一个 skb”在各阶段代表的工作量不同，所以只统计 skb/s 往往不足以解释 PPS、吞吐和 CPU。

---

## 17. 可执行的诊断方法

### 17.1 查看 socket 和协议内存

```bash
ss -mti
cat /proc/net/sockstat
cat /proc/net/sockstat6
nstat -az
```

重点观察：

- `Recv-Q` / `Send-Q`；
- `skmem` 中的接收、发送、backlog 和 limit；
- TCP retransmit、listen overflow；
- IP/UDP/TCP checksum 和 buffer error。

### 17.2 查看 slab 和 softirq

```bash
slabtop -o
grep -E 'skbuff|sock_inode' /proc/slabinfo
cat /proc/softirqs
cat /proc/net/softnet_stat
```

`skbuff_head_cache` 增长不必然是泄漏，slab 会缓存已释放对象。需要结合持续趋势、
socket 数量和流量判断。

### 17.3 查看 netdev、ring 和 offload

```bash
ip -s -s link show dev eth0
ethtool -S eth0
ethtool -g eth0
ethtool -k eth0
tc -s qdisc show dev eth0
tc -s filter show dev eth0 ingress
```

常见关联：

| 现象                         | 优先检查                                          |
| ---------------------------- | ------------------------------------------------- |
| RX drop 且 softnet drop 增长 | NAPI budget、CPU backlog、RPS、CPU 饱和           |
| driver `rx_no_buffer` 增长   | RX refill、page_pool、内存压力、ring 大小         |
| TX queue stopped 时间长      | TX completion、BQL、descriptor 回收、中断亲和     |
| qdisc drop                   | 队列上限、整形速率、拥塞和 pacing                 |
| checksum error               | `ip_summed`、隧道层级、驱动 descriptor 配置       |
| GRO 后 CPU 仍高              | flow 数、GRO flush、包不可合并、Netfilter/TC 成本 |

### 17.4 使用 tracepoint 观察释放

先查看目标内核提供的事件和字段：

```bash
sudo bpftrace -l 'tracepoint:skb:*'
sudo cat /sys/kernel/tracing/events/skb/kfree_skb/format
```

再按实际字段追踪：

```bash
sudo bpftrace -e '
tracepoint:skb:kfree_skb
{
    @[args->reason] = count();
}'
```

也可以使用：

```bash
sudo perf list 'skb:*'
sudo trace-cmd list -e skb
sudo dropwatch -l kas
```

tracepoint ABI 和工具语法会随发行版变化，应以本机列出的事件为准。

### 17.5 追踪时必须问清楚观察点

```text
NIC hardware counter
  ≠ driver descriptor
  ≠ XDP frame
  ≠ pre-GRO packet
  ≠ post-GRO skb
  ≠ socket message
  ≠ application read()
```

如果两个工具统计不一致，先确认它们观察的是哪一种对象，而不是直接判断某个工具错误。

---

## 18. 常见误区

### 误区一：一个 skb 永远等于一个线上的包

GRO 后一个 skb 可包含多个接收 segment；GSO/TSO 前一个大 skb 会产生多个发送 segment。

### 误区二：skb 数据一定连续

大量 RX/TX skb 是 non-linear 的。读取任意 offset 前需要考虑 page frags。

### 误区三：clone 只是增加 `users`

`skb_clone()` 创建新描述符，共享数据区并增加 `dataref`。`skb_get()` 才是增加同一描述符
的 `users`。

### 误区四：有 headroom 就可以写头

clone 后 headroom 可能仍是共享的。修改前应使用 `skb_cow_head()` 等 helper。

### 误区五：page_pool 等于用户态零拷贝

page_pool 优化的是驱动 RX page 和 DMA 生命周期。普通 socket `recv()` 通常仍复制。

### 误区六：TX completion 一定由 `NET_TX_SOFTIRQ` 处理

许多驱动通过 NAPI 清理 TX completion，因此执行上下文可能是 `NET_RX_SOFTIRQ`。
`NET_TX_SOFTIRQ` 主要处理 qdisc 调度和部分延迟释放工作。

### 误区七：`dev_queue_xmit()` 会先积累固定数量

qdisc 通常会尝试立即运行；只有 pacing、quota、锁竞争或设备队列状态等条件阻止时，
才留到后续调度。

---

## 19. 总结

理解 `sk_buff` 可以浓缩为五个问题：

```text
1. 数据在哪里？
   linear head、frags[] 还是 frag_list

2. 当前层看哪里？
   data 和 mac/network/transport header offsets

3. 谁拥有它？
   queue、socket、driver、clone holder

4. 哪部分被共享？
   skb users 还是 shared dataref

5. 释放后去哪里？
   slab、page allocator、page_pool 或 socket accounting
```

核心关系：

```text
len = linear data + non-linear data
data_len = non-linear data
headlen = len - data_len

skb_get()   → share one descriptor
skb_clone() → new descriptor, shared packet storage
skb_copy()  → independent packet storage

RX: DMA/page_pool → XDP → skb/GRO → protocol/socket
TX: socket → skb/GSO → qdisc/driver → completion/free
```

掌握这些语义后，再阅读 Netdevice、NAPI、TCP、Netfilter、GRO/GSO 和驱动代码时，
就能判断每一步究竟是在移动字节、修改元数据、共享内存，还是转移所有权。

**下一章：**
[[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]

---

## 参考资料

- [Linux kernel sk_buff documentation](https://docs.kernel.org/networking/skbuff.html)
- [Linux kernel page_pool documentation](https://docs.kernel.org/networking/page_pool.html)
- [Linux kernel segmentation offloads](https://docs.kernel.org/networking/segmentation-offloads.html)
- [Linux kernel checksum offloads](https://docs.kernel.org/networking/checksum-offloads.html)
- [Linux kernel NAPI documentation](https://docs.kernel.org/networking/napi.html)
- [[2026-04-09-dpdk-deep-dive-ch5-mbuf-mechanism|DPDK Mbuf 机制对比]]
- [[2026-04-08-ebpf-deep-dive-ch6-tc-traffic-control|eBPF TC 钩子]]
