---
title: "DPDK 深度探索 ch25：Virtio 驱动"
date: 2026-04-10 08:00:00
tags: [dpdk, virtio, vhost, vm, para-virtualization, pmd, scatter-gather]
description: "深入解析 DPDK Virtio PMD：virtio 原理、virtqueue、接收 refill、合并写入、vhost-user 协同"
---

# DPDK 深度探索 ch25：Virtio 驱动

> [!abstract] 核心要点
> Virtio 是面向虚拟机的半虚拟化设备框架。DPDK virtio PMD 提供高性能 virtio 设备驱动，本章深入解析 virtqueue 机制、接收 refill 流程、多队列支持。

## 1. Virtio 概述

### 1.1 为什么需要 Virtio

```
全虚拟化 vs 半虚拟化：

全虚拟化 (QEMU 默认):
  Guest OS → 模拟硬件设备 → Hypervisor → 真实硬件
                ↑
            复杂模拟，效率低

半虚拟化 (Virtio):
  Guest OS → Virtio 驱动 → Virtqueue → Hypervisor → 真实硬件
                ↑                    ↑
            简化为 ring buffer      高效

性能对比 (近似值):
  - e1000 (模拟): ~0.5 Gbps
  - virtio-net:   ~10 Gbps
  - vhost-user:   ~15-20 Gbps
```

### 1.2 Virtio vs 其他 VM 网络方案

| 方案           | 架构        | 性能 | 复杂度 |
| -------------- | ----------- | ---- | ------ |
| **e1000**      | 软件模拟    | 低   | 低     |
| **virtio-net** | 半虚拟化    | 中   | 中     |
| **vhost-net**  | kernel 加速 | 高   | 中     |
| **vhost-user** | 用户态加速  | 最高 | 高     |

## 2. Virtqueue 架构

### 2.1 Virtqueue 结构

Virtqueue 是 Virtio 的核心数据结构，是 Guest 和 Host 之间共享的环形缓冲区：

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtqueue                                │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  Descriptor Table                      │  │
│  │  ┌────────┬────────┬────────┬────────┐              │  │
│  │  │ Desc 0 │ Desc 1 │ Desc 2 │ Desc 3 │ ...        │  │
│  │  └────────┴────────┴────────┴────────┘              │  │
│  │  每个 descriptor: addr(8B) + len(4B) + flags(2B) +  │  │
│  │                       next(2B) = 16 bytes           │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────┐    ┌───────────────────┐              │
│  │  Available Ring  │    │     Used Ring     │              │
│  │  (Guest → Host) │    │   (Host → Guest) │              │
│  │                   │    │                   │              │
│  │ flags            │    │ flags              │              │
│  │ idx              │    │ idx                │              │
│  │ ring[0..N]      │    │ ring[0..N]       │              │
│  │ used_event       │    │ avail_event       │              │
│  └───────────────────┘    └───────────────────┘              │
└─────────────────────────────────────────────────────────────┘
```

> [!note] Available vs Used 的方向
>
> - **Available Ring**：Guest 告诉 Host "这些 descriptor 可用"，Guest 写、Host 读
> - **Used Ring**：Host 告诉 Guest "这些 descriptor 我用完了"，Host 写、Guest 读

### 2.2 Descriptor

```c
// drivers/net/virtio/virtio_ring.h

// Virtio descriptor (16 bytes)
struct vring_desc {
    uint64_t addr;      // 缓冲区地址 (Guest Physical Address)
    uint32_t len;       // 缓冲区长度
    uint16_t flags;     // 控制标志
    uint16_t next;      // 下一个 descriptor 的索引 (链表)
};

// Flags (注意 DPDK 前缀是 VRING_ 不是 VIRTQ_)
#define VRING_DESC_F_NEXT       1  // 链表中还有下一个 descriptor
#define VRING_DESC_F_WRITE      2  // 只写缓冲区 (Host 会写入，用于 RX)
#define VRING_DESC_F_INDIRECT   4  // 间接描述符表
```

```
┌─────────────────────────────────────────────────────────────┐
│               Descriptor 链表示例                           │
│                                                              │
│  TX 方向 (Guest → Host):                                    │
│  ┌─────────┐     ┌─────────┐     ┌─────────┐              │
│  │ Desc 0  │────→│ Desc 1  │     │ Desc 2  │              │
│  │ addr    │     │ addr    │     │ addr    │              │
│  │ len=128 │     │ len=512 │     │ len=860 │              │
│  │ NEXT    │     │ NEXT    │     │ (none)  │              │
│  └─────────┘     └─────────┘     └─────────┘              │
│  注意: TX 方向没有 WRITE flag                               │
│                                                              │
│  RX 方向 (Host → Guest):                                    │
│  ┌─────────┐                                                │
│  │ Desc 0  │                                                │
│  │ addr    │                                                │
│  │ len=2048│                                                │
│  │ WRITE   │  ← Host 会将收到的数据写入这个缓冲区            │
│  └─────────┘                                                │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 Available 和 Used Ring

```c
// drivers/net/virtio/virtio_ring.h

// Available Ring (Guest 写入，Host 读取)
struct vring_avail {
    uint16_t flags;       // VIRTIO_AVAIL_F_NO_INTERRUPT = 1
    uint16_t idx;         // Guest 写入下一个位置的索引
    uint16_t ring[];      // descriptor 索引数组 (柔性数组)
    // 后面跟着 used_event
};

// Used Ring (Host 写入，Guest 读取)
struct vring_used_elem {
    uint32_t id;          // descriptor chain 的起始索引
    uint32_t len;         // 写入的总字节数
};

struct vring_used {
    uint16_t flags;       // VIRTIO_USED_F_NO_NOTIFY = 1
    RTE_ATOMIC(uint16_t) idx;  // Host 写入下一个位置的索引
    struct vring_used_elem ring[];  // 已完成的元素 (柔性数组)
    // 后面跟着 avail_event
};
```

### 2.4 DPDK Virtqueue 内部结构

```c
// drivers/net/virtio/virtqueue.h

// 每个描述符的额外信息
struct vq_desc_extra {
    void *cookie;     // 关联的 mbuf 指针
    uint16_t ndescs;  // 此 chain 占用的 descriptor 数量
    uint16_t next;    // free chain 中的下一个
};

// Virtqueue 结构 (简化)
struct virtqueue {
    struct virtio_hw *hw;

    union {
        struct {
            struct vring ring;  // desc + avail + used
        } vq_split;             // Split virtqueue
        struct {
            struct vring_packed ring;
            bool used_wrap_counter;
            uint16_t cached_flags;
        } vq_packed;            // Packed virtqueue
    };

    uint16_t vq_used_cons_idx;  // Guest 已消费到的位置
    uint16_t vq_nentries;       // descriptor 总数
    uint16_t vq_free_cnt;       // 当前空闲 descriptor 数
    uint16_t vq_avail_idx;      // Available ring 写入位置
    uint16_t vq_free_thresh;    // 空闲阈值 (低于此值触发 refill)

    uint16_t vq_desc_head_idx;  // Free chain 头部
    uint16_t vq_desc_tail_idx;  // Free chain 尾部
    uint16_t vq_queue_index;    // PCI queue 编号

    void *vq_ring_virt_mem;     // vring 虚拟地址
    unsigned int vq_ring_size;  // vring 大小

    uint16_t *notify_addr;      // Kick 通知地址
    struct vq_desc_extra vq_descx[];  // 每个 descriptor 的额外信息
};
```

```
┌─────────────────────────────────────────────────────────────┐
│              Virtqueue 内存布局                              │
│                                                              │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Descriptor Table                                │      │
│  │  vring.desc[0..N-1]  (每个 16 bytes)            │      │
│  └──────────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Available Ring                                   │      │
│  │  vring.avail.flags(2B) + idx(2B) + ring[](2B*N) │      │
│  │  + used_event(2B)                                │      │
│  └──────────────────────────────────────────────────┘      │
│  ┌──────────────────────────────────────────────────┐      │
│  │  Used Ring                                        │      │
│  │  vring.used.flags(2B) + idx(2B)                  │      │
│  │  + ring[](8B*N: id(4B)+len(4B))                 │      │
│  │  + avail_event(2B)                               │      │
│  └──────────────────────────────────────────────────┘      │
│                                                              │
│  Guest 和 Host 共享这块内存 (通过 GPA 映射)                 │
└─────────────────────────────────────────────────────────────┘
```

## 3. DPDK Virtio PMD

### 3.1 Virtio PMD 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK Virtio PMD                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                Application                             │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │         rte_eth_rx_burst() / rte_eth_tx_burst()      │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              virtio_recv_pkts()                       │  │
│  │              virtio_xmit_pkts()                       │  │
│  │              (还有 packed / inorder 变体)              │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Virtqueue 操作                           │  │
│  │  - 读写 vring.desc / avail / used                    │  │
│  │  - Free chain 管理                                   │  │
│  │  - virtqueue_notify() kick Host                     │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

DPDK 的 virtio PMD 支持三种 virtqueue 模式，对应不同的 burst 函数：

```c
// drivers/net/virtio/virtio_rxtx.c

// Split virtqueue (标准模式)
uint16_t virtio_recv_pkts(void *rx_queue, struct rte_mbuf **rx_pkts,
                           uint16_t nb_pkts);
uint16_t virtio_xmit_pkts(void *tx_queue, struct rte_mbuf **tx_pkts,
                           uint16_t nb_pkts);

// Packed virtqueue (紧凑模式)
uint16_t virtio_recv_pkts_packed(void *rx_queue, struct rte_mbuf **rx_pkts,
                                  uint16_t nb_pkts);
uint16_t virtio_xmit_pkts_packed(void *tx_queue, struct rte_mbuf **tx_pkts,
                                  uint16_t nb_pkts);

// In-order (按序完成模式)
uint16_t virtio_recv_pkts_inorder(void *rx_queue, struct rte_mbuf **rx_pkts,
                                   uint16_t nb_pkts);
uint16_t virtio_xmit_pkts_inorder(void *tx_queue, struct rte_mbuf **tx_pkts,
                                   uint16_t nb_pkts);

// Mergeable RX (合并缓冲区模式)
uint16_t virtio_recv_mergeable_pkts(void *rx_queue, struct rte_mbuf **rx_pkts,
                                     uint16_t nb_pkts);
uint16_t virtio_recv_mergeable_pkts_packed(void *rx_queue,
                                           struct rte_mbuf **rx_pkts,
                                           uint16_t nb_pkts);
```

### 3.2 Guest virtio PMD 与 Host 后端

虚拟机场景下，Guest 内的 DPDK virtio PMD **不是直连物理网卡**。它驱动的是
Guest 看到的 virtio-net 设备；真正连接物理网卡的是 Host 侧后端，例如
vhost-net、vhost-user、OVS-DPDK、VPP 或 vDPA。

经典 vhost-user 场景的数据路径如下：

```
                         Host / Physical Machine
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  Physical NIC                                                        │
│  ┌──────────────┐                                                    │
│  │   RX Queue   │                                                    │
│  └──────┬───────┘                                                    │
│         │ DMA 到 Host hugepage mbuf                                  │
│         ▼                                                            │
│  Host NIC PMD                                                        │
│  mlx5 / i40e / ixgbe PMD                                             │
│         │                                                            │
│         │ rte_eth_rx_burst()                                         │
│         ▼                                                            │
│  OVS-DPDK / VPP / DPDK vhost backend                                 │
│  ┌──────────────────────────────┐                                    │
│  │  查流表 / 转发决策            │                                    │
│  │  output: vhost-user port     │                                    │
│  └──────────────┬───────────────┘                                    │
│                 │                                                    │
│                 │ vhost-user backend                                 │
│                 │ 读取 Guest RX virtqueue 的空 descriptor             │
│                 │ 把 packet data 写入 Guest 提供的 RX buffer          │
│                 ▼                                                    │
│        vhost-user socket                                             │
│        /var/run/vhost-user0.sock                                     │
│                 │                                                    │
└─────────────────┼────────────────────────────────────────────────────┘
                  │
                  │ Guest hugepage memory 被 QEMU/vhost 后端映射到 Host
                  ▼
                              Guest VM
┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  virtio-net PCI device                                               │
│  ┌──────────────────────────────┐                                    │
│  │ RX virtqueue                 │                                    │
│  │ avail ring: Guest 提供空 buffer│                                    │
│  │ used ring : Host 填好包后返回  │                                    │
│  └──────────────┬───────────────┘                                    │
│                 │                                                    │
│                 │ virtio PMD 轮询 used ring                          │
│                 │ rte_eth_rx_burst()                                 │
│                 ▼                                                    │
│  Guest DPDK App                                                      │
│  ┌──────────────────────────────┐                                    │
│  │ struct rte_mbuf *pkts[]      │                                    │
│  │ packet data 已写入 Guest mbuf │                                    │
│  └──────────────────────────────┘                                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

RX 方向的关键流程：

1. Guest virtio PMD 提前分配 mbuf，并把空 RX buffer 通过 descriptor 挂到
   available ring。
2. Host vhost-user backend 可以访问 Guest hugepage memory，因此能看到这些
   virtqueue descriptor。
3. 物理 NIC 收到包后，Host PMD 先把包收到 Host mbuf。
4. OVS-DPDK/VPP/DPDK vhost backend 查流表，决定输出到某个 vhost-user port。
5. vhost backend 从 Guest RX virtqueue 取一个空 buffer，把 packet data 写进去，
   然后更新 used ring。
6. Guest virtio PMD 轮询 used ring，`rte_eth_rx_burst()` 返回已经填好数据的
   `rte_mbuf`。

TX 方向反过来：

```
Guest DPDK App
  -> rte_eth_tx_burst()
  -> virtio PMD
  -> TX virtqueue available ring
  -> Host vhost-user backend
  -> OVS-DPDK / VPP 转发
  -> Host NIC PMD
  -> Physical NIC TX Queue
```

因此可以把职责边界理解为：

| 组件             | 作用                                                                 |
| ---------------- | -------------------------------------------------------------------- |
| Guest virtio PMD | 驱动 Guest 内 virtio-net 设备，读写 virtqueue                        |
| vhost-user 后端  | Host 侧访问 Guest virtqueue，在 Guest buffer 与 Host mbuf 间搬运数据 |
| Host NIC PMD     | 驱动物理网卡，从物理 RX/TX queue 收发包                              |
| OVS-DPDK / VPP   | Host 侧虚拟交换或转发平面，决定包进入哪个 VM 或物理端口              |

这最后一行已经属于云网络设计：Host 上通常不只有一个 VM，也不只有一个出口。
同一台物理机上可能同时存在多个 VM vhost-user port、物理 NIC port、overlay tunnel port
和本地服务端口，因此需要一个虚拟交换或转发平面来执行云网络规则。

#### 控制面：决定虚拟网络长什么样

控制面不直接搬运每个 packet，它负责创建拓扑和下发规则：

```
Cloud API / OpenStack Neutron / Kubernetes CNI / libvirt
        │
        │ 创建 VM、端口、网络、子网、安全组、路由、浮动 IP
        ▼
Network Controller
OVN Northbound / Neutron Server / SDN Controller
        │
        │ 生成逻辑交换机、逻辑路由器、ACL、NAT、QoS、tunnel 信息
        ▼
Host Agent
ovn-controller / ovs-vswitchd / vpp-agent / 自研 agent
        │
        │ 在本机落实配置
        │ - 创建 vhost-user socket
        │ - 启动 QEMU virtio-net 设备
        │ - 将 VM port 接入 bridge / datapath
        │ - 下发 flow table / ACL / tunnel / route
        ▼
Host Datapath
OVS-DPDK / VPP / Linux bridge / TC / eBPF
```

控制面最终回答的是：

```text
这个 VM 的 vNIC 属于哪个网络？
这个 vNIC 对应哪个 vhost-user port？
发往某个 MAC/IP/VNI 的包应该进入哪个 VM、哪个 tunnel 或哪个物理口？
安全组、ACL、NAT、QoS 应该怎么执行？
```

#### 数据面：按规则转发每个 packet

数据面是真正处理 packet 的路径。以 vhost-user + OVS-DPDK/VPP 为例：

```text
外部包进入 VM：

Physical NIC
  -> Host NIC PMD
  -> OVS-DPDK / VPP datapath
       match: dst MAC / VLAN / VNI / IP / 5-tuple
       actions:
         - security group / ACL
         - tunnel decap
         - NAT / route / bridge lookup
         - output: vhost-user port of VM-A
  -> vhost-user backend
  -> Guest RX virtqueue
  -> Guest virtio PMD
  -> Guest DPDK app / Guest kernel
```

```text
VM 发包到外部：

Guest app / Guest kernel
  -> Guest virtio PMD
  -> Guest TX virtqueue
  -> vhost-user backend
  -> OVS-DPDK / VPP datapath
       match: src VM port / dst MAC / IP / tunnel metadata
       actions:
         - security group / ACL
         - NAT / route / bridge lookup
         - tunnel encap
         - output: physical NIC port
  -> Host NIC PMD
  -> Physical NIC
```

```text
同 Host 上 VM-A 到 VM-B：

VM-A virtio TX
  -> vhost-user port A
  -> OVS-DPDK / VPP datapath
       match: dst MAC = VM-B
       action: output vhost-user port B
  -> VM-B virtio RX
```

所以 virtio/vhost 只解决 **Guest 和 Host datapath 之间如何高效传包**；
包最终进入哪个 VM、哪个 tunnel、哪个物理端口，是云网络控制面下发规则后，
由 Host 数据面执行的结果。

如果 VM 需要更接近直通物理网卡的路径，通常使用 SR-IOV VF 或 PCI passthrough。
这种情况下 Guest 内看到的是 VF/物理设备，使用的是 mlx5、i40e、ixgbe 等真实
NIC PMD，而不是 virtio PMD。

### 3.3 初始化流程

```c
// drivers/net/virtio/virtio_ethdev.c (简化)

// Virtio 设备初始化
static int
virtio_init_device(struct rte_eth_dev *eth_dev)
{
    struct virtio_hw *hw = eth_dev->data->dev_private;

    // 1. 协商 feature bits (与 Host 协商支持哪些特性)
    //    例如: VIRTIO_NET_F_MRG_RXBUF, VIRTIO_NET_F_MQ, VIRTIO_F_RING_PACKED
    virtio_negotiate_features(hw, hw->req_guest_features);

    // 2. 读取 Host 通知的 queue size
    //    通过 PCI 配置空间或 virtio config space 获取
    //    queue size 必须是 2 的幂

    // 3. 配置 RX/TX queue
    //    每个 queue pair 创建一个 virtqueue
    //    内部调用 virtqueue_alloc() 分配 vring 内存

    return 0;
}

// 分配 virtqueue (drivers/net/virtio/virtqueue.c)
struct virtqueue *
virtqueue_alloc(struct virtio_hw *hw, uint16_t queue_index,
               uint16_t vq_size, int numa_node)
{
    struct virtqueue *vq;

    // 1. 计算 vring 所需内存大小
    size_t sz = vring_size(vq_size, VIRTIO_PCI_VRING_ALIGN);
    // 2. 分配连续物理内存 (Host 需要通过 GPA 访问)
    const struct rte_memzone *mz = rte_memzone_reserve_aligned(
        name, sz, numa_node, 0, VIRTIO_PCI_VRING_ALIGN);

    // 3. 初始化 vring: 设置 desc, avail, used 指针
    vring_init(&vq->vq_split.ring, vq_size, mz->addr,
               VIRTIO_PCI_VRING_ALIGN);

    // 4. 初始化 free chain (所有 descriptor 链成空闲链表)
    for (i = 0; i < vq_size - 1; i++)
        vq->vq_split.ring.desc[i].next = i + 1;
    vq->vq_split.ring.desc[vq_size - 1].next = VQ_RING_DESC_CHAIN_END;

    return vq;
}
```

## 4. 接收流程 (Refill)

### 4.1 RX Refill 流程

> [!important] Refill 是什么？
> Virtio RX 的核心是 **refill**（重新填充）：Guest 必须提前将空闲缓冲区
> 放入 Available Ring，Host 收到包后才能将数据写入这些缓冲区。
> 如果 Available Ring 中没有空闲缓冲区，Host 只能丢包。

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio RX Refill 流程                     │
│                                                              │
│  阶段 1: Guest Refill (提供空闲缓冲区)                      │
│  ─────────────────────────────────────                      │
│  1. Guest 分配空 mbuf                                       │
│  2. 将 mbuf 的 GPA 填入 descriptor (flags = WRITE)         │
│  3. 将 descriptor 索引写入 Available Ring                   │
│  4. 更新 avail.idx                                         │
│  5. Kick Host (写 notify 寄存器)                            │
│                                                              │
│  阶段 2: Host 接收 (填写数据)                                │
│  ─────────────────────────────────────                      │
│  6. Host 从 Available Ring 取出 descriptor                  │
│  7. 将收到的包数据写入 descriptor 指向的缓冲区               │
│  8. 将 descriptor 索引和写入长度写入 Used Ring               │
│  9. 更新 used.idx                                          │
│  10. 中断通知 Guest (如果启用了中断)                         │
│                                                              │
│  阶段 3: Guest 回收 (取出已完成的包)                         │
│  ─────────────────────────────────────                      │
│  11. Guest 检查 used.idx 是否前进                           │
│  12. 从 Used Ring 取出已完成的 descriptor                    │
│  13. 关联 mbuf，设置 data_len / pkt_len                    │
│  14. 将 mbuf 返回给调用者                                   │
│  15. 释放 descriptor 回 free chain                          │
│  16. 回到阶段 1，补充新的空闲缓冲区 (refill)                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 RX Burst 实现 (简化)

```c
// 基于 drivers/net/virtio/virtio_rxtx.c 中 virtio_recv_pkts() 简化

static uint16_t
virtio_recv_pkts(void *rx_queue,
                 struct rte_mbuf **rx_pkts,
                 uint16_t nb_pkts)
{
    struct virtqueue *vq = rx_queue;
    struct vring_used *used = vq->vq_split.ring.used;
    struct vring_desc *desc = vq->vq_split.ring.desc;
    uint16_t nb_recv = 0;

    // 1. 检查 Used Ring 是否有新完成的 descriptor
    while (nb_recv < nb_pkts &&
           vq->vq_used_cons_idx != rte_atomic_load_explicit(&used->idx,
                       rte_memory_order_acquire)) {

        // 2. 从 Used Ring 取出已完成的元素
        uint16_t used_idx = vq->vq_used_cons_idx & (vq->vq_nentries - 1);
        uint32_t desc_idx = used->ring[used_idx].id;
        uint32_t len = used->ring[used_idx].len;

        // 3. 通过 cookie 获取关联的 mbuf
        struct rte_mbuf *mbuf = (struct rte_mbuf *)vq->vq_descx[desc_idx].cookie;

        // 4. 设置 mbuf 数据长度
        rte_pktmbuf_data_len(mbuf) = (uint16_t)len;
        rte_pktmbuf_pkt_len(mbuf) = (uint16_t)len;

        rx_pkts[nb_recv++] = mbuf;

        // 5. 释放 descriptor 回 free chain
        vq->vq_descx[desc_idx].ndescs = 0;
        vq->vq_desc_head_idx = desc_idx;
        vq->vq_free_cnt++;

        vq->vq_used_cons_idx++;
    }

    // 6. 如果空闲 descriptor 低于阈值，触发 refill
    if (vq->vq_free_cnt < vq->vq_free_thresh)
        virtio_rxq_refill(vq);

    return nb_recv;
}
```

### 4.3 RX Refill 实现 (简化)

```c
// 将空闲 mbuf 填入 Available Ring

static void
virtio_rxq_refill(struct virtqueue *vq)
{
    struct vring_desc *desc = vq->vq_split.ring.desc;
    struct vring_avail *avail = vq->vq_split.ring.avail;
    uint16_t nb_refill = 0;

    // 持续填充直到 free chain 用完或达到阈值
    while (vq->vq_free_cnt > 0 && nb_refill < vq->vq_free_thresh) {
        // 1. 从 free chain 取出空闲 descriptor
        uint16_t desc_idx = vq->vq_desc_head_idx;
        vq->vq_desc_head_idx = desc[desc_idx].next;
        vq->vq_free_cnt--;

        // 2. 分配 mbuf
        struct rte_mbuf *mbuf = rte_pktmbuf_alloc(rx_mbuf_pool);
        if (mbuf == NULL)
            break;

        // 3. 填充 descriptor (WRITE: Host 会写入数据)
        desc[desc_idx].addr = rte_pktmbuf_iova(mbuf);
        desc[desc_idx].len = mbuf->buf_len - RTE_PKTMBUF_HEADROOM;
        desc[desc_idx].flags = VRING_DESC_F_WRITE;

        // 4. 保存 mbuf 引用到 cookie
        vq->vq_descx[desc_idx].cookie = mbuf;

        // 5. 将 descriptor 索引写入 Available Ring
        uint16_t avail_idx = avail->idx & (vq->vq_nentries - 1);
        avail->ring[avail_idx] = desc_idx;

        avail->idx++;
        nb_refill++;
    }

    // 6. Kick Host (通知有新的空闲缓冲区)
    if (nb_refill > 0)
        virtqueue_notify(vq);
}
```

## 5. 发送流程

### 5.1 TX 发送

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio TX 发送流程                        │
│                                                              │
│  1. Guest 准备 mbuf 数据                                    │
│     ↓                                                        │
│  2. 从 free chain 取出空闲 descriptor                       │
│     ↓                                                        │
│  3. 填充 descriptor (addr=GPA, len, flags=NEXT 链)         │
│     ↓                                                        │
│  4. 将 chain 头的 descriptor 索引写入 Available Ring       │
│     ↓                                                        │
│  5. 更新 avail.idx                                         │
│     ↓                                                        │
│  6. Kick Host (写 notify 寄存器)                            │
│     ↓                                                        │
│  7. Host 从 Available Ring 取出 descriptor chain           │
│     ↓                                                        │
│  8. Host 读取数据，发送到网络                                │
│     ↓                                                        │
│  9. Host 将 descriptor 索引写入 Used Ring                  │
│     ↓                                                        │
│  10. Guest 回收: 从 Used Ring 取出 descriptor, 释放 mbuf   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 TX Burst 实现 (简化)

```c
// 基于 drivers/net/virtio/virtio_rxtx.c 中 virtio_xmit_pkts() 简化

static uint16_t
virtio_xmit_pkts(void *tx_queue,
                 struct rte_mbuf **tx_pkts,
                 uint16_t nb_pkts)
{
    struct virtqueue *vq = tx_queue;
    struct vring_desc *desc = vq->vq_split.ring.desc;
    struct vring_avail *avail = vq->vq_split.ring.avail;
    uint16_t nb_sent = 0;

    while (nb_sent < nb_pkts && vq->vq_free_cnt >= 2) {
        struct rte_mbuf *mbuf = tx_pkts[nb_sent];

        // 1. 从 free chain 取出 descriptor (TX 至少需要 2 个:
        //    一个数据，一个 header)
        uint16_t head_idx = vq->vq_desc_head_idx;
        uint16_t prev_idx = head_idx;

        // 2. 填充数据 descriptor
        desc[head_idx].addr = rte_pktmbuf_iova(mbuf);
        desc[head_idx].len = rte_pktmbuf_data_len(mbuf);
        desc[head_idx].flags = VRING_DESC_F_NEXT;  // 还有 header

        // 3. 取下一个 descriptor 填充 virtio-net header
        uint16_t hdr_idx = desc[head_idx].next;
        desc[hdr_idx].addr = hdr_addr;
        desc[hdr_idx].len = sizeof(struct virtio_net_hdr);
        desc[hdr_idx].flags = 0;  // chain 结尾

        // 4. 保存 mbuf 到 cookie (发送完成后用于释放)
        vq->vq_descx[head_idx].cookie = mbuf;
        vq->vq_descx[head_idx].ndescs = 2;

        // 5. 更新 free chain
        vq->vq_desc_head_idx = desc[hdr_idx].next;
        vq->vq_free_cnt -= 2;

        // 6. 将 chain 头索引写入 Available Ring
        uint16_t avail_idx = avail->idx & (vq->vq_nentries - 1);
        avail->ring[avail_idx] = head_idx;
        avail->idx++;

        nb_sent++;
    }

    // 7. Kick Host
    if (nb_sent > 0)
        virtqueue_notify(vq);

    return nb_sent;
}
```

### 5.3 TX Cleanup (回收已发送的包)

```c
// 发送完成后的清理 (在 TX burst 开头或独立的 cleanup 函数中)

static void
virtio_xmit_cleanup(struct virtqueue *vq, uint16_t num)
{
    struct vring_used *used = vq->vq_split.ring.used;
    uint16_t nb_cleaned = 0;

    while (nb_cleaned < num &&
           vq->vq_used_cons_idx != rte_atomic_load_explicit(&used->idx,
                       rte_memory_order_acquire)) {

        uint16_t used_idx = vq->vq_used_cons_idx & (vq->vq_nentries - 1);
        uint32_t desc_idx = used->ring[used_idx].id;

        // 释放关联的 mbuf
        struct rte_mbuf *mbuf = (struct rte_mbuf *)vq->vq_descx[desc_idx].cookie;
        rte_pktmbuf_free(mbuf);

        // 将 descriptor 归还 free chain
        uint16_t ndescs = vq->vq_descx[desc_idx].ndescs;
        vq->vq_free_cnt += ndescs;
        // ... 将 ndescs 个 descriptor 重新链入 free chain

        vq->vq_used_cons_idx++;
        nb_cleaned++;
    }
}
```

## 6. 多队列支持

### 6.1 多队列原理

```
┌─────────────────────────────────────────────────────────────┐
│                    多队列 Virtio                              │
│                                                              │
│  Guest OS                                                    │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
│  │ Queue 0  │ │ Queue 1  │ │ Queue 2  │ │ Queue 3  │      │
│  │ (RX+TX)  │ │ (RX+TX)  │ │ (RX+TX)  │ │ (RX+TX)  │      │
│  │ lcore 0  │ │ lcore 1  │ │ lcore 2  │ │ lcore 3  │      │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘      │
│       └────────────┴────────────┴────────────┘             │
│                           ↓                                  │
│  Virtio Feature: VIRTIO_NET_F_MQ (多队列)                   │
│  Guest 通过 ctrl queue 配置 max_queues                      │
│  Host (vhost-user) 通过 RSS 将流分配到不同队列              │
│                                                              │
│  配置:                                                       │
│    - 每个 lcore 绑定独立的 RX/TX queue pair                 │
│    - Host 端根据 5-tuple hash 选择目标队列                  │
│    - 典型配置: 1-2 queues/core                              │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 多队列配置

```c
// 通过 rte_eth_dev_configure 配置多队列

// 1. 配置 ethdev
struct rte_eth_conf conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,  // 启用 RSS 多队列
    },
    .rx_adv_conf.rss_conf = {
        .rss_key = rss_key,
        .rss_key_len = 40,
        .rss_hf = RTE_ETH_RSS_IP | RTE_ETH_RSS_TCP | RTE_ETH_RSS_UDP,
    },
};

// 2. 设置 RX/TX queue 数量
uint16_t nb_rx_queues = 4;  // 4 个 RX queue
uint16_t nb_tx_queues = 4;  // 4 个 TX queue
rte_eth_dev_configure(port_id, nb_rx_queues, nb_tx_queues, &conf);

// 3. 配置并启动每个 queue
for (uint16_t q = 0; q < nb_rx_queues; q++) {
    rte_eth_rx_queue_setup(port_id, q, nb_rxd,
        rte_socket_id(), &rx_conf, mbuf_pool);
}

// 4. 每个 lcore 绑定独立的 queue pair
// lcore 0 → queue 0
// lcore 1 → queue 1
// ...
```

## 7. Mergeable RX (合并缓冲区)

### 7.1 为什么需要 Mergeable

> [!note] VIRTIO_NET_F_MRG_RXBUF
> 当协商了这个 feature 后，Host 可以将一个大包拆分成多个 descriptor，
> 每个 descriptor 指向一个小缓冲区。Guest 收到后需要将它们"合并"成一个 mbuf chain。

```
┌─────────────────────────────────────────────────────────────┐
│              Mergeable RX 示例 (1500B 的包)                  │
│                                                              │
│  不使用 Mergeable:                                           │
│  - Guest 必须提供 ≥ 1514B 的缓冲区                          │
│  - 浪费内存: 每个 mbuf 2KB，但小包也占 2KB                  │
│                                                              │
│  使用 Mergeable:                                             │
│  - Guest 提供 512B 的小缓冲区                                │
│  - 大包被拆成 3 个 descriptor:                              │
│                                                              │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐                  │
│  │ Desc 0  │──→│ Desc 1  │──→│ Desc 2  │                  │
│  │ 512B    │   │ 512B    │   │ 476B    │                  │
│  │ header  │   │ data    │   │ data    │                  │
│  └─────────┘   └─────────┘   └─────────┘                  │
│                                                              │
│  Guest 将它们链成 mbuf chain:                               │
│  mbuf_head → mbuf1 → mbuf2                                  │
│  pkt_len = 1500, nb_segs = 3                                │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 DPDK 的 Mergeable 处理

DPDK 通过 `virtio_recv_mergeable_pkts()` 处理合并缓冲区，内部流程如下：

```c
// 基于 virtio_recv_mergeable_pkts() 简化

static uint16_t
virtio_recv_mergeable_pkts(void *rx_queue,
                            struct rte_mbuf **rx_pkts,
                            uint16_t nb_pkts)
{
    struct virtqueue *vq = rx_queue;
    struct vring_used *used = vq->vq_split.ring.used;
    struct vring_desc *desc = vq->vq_split.ring.desc;
    uint16_t nb_recv = 0;

    while (nb_recv < nb_pkts &&
           vq->vq_used_cons_idx != rte_atomic_load_explicit(&used->idx,
                       rte_memory_order_acquire)) {

        uint16_t used_idx = vq->vq_used_cons_idx & (vq->vq_nentries - 1);
        uint32_t desc_idx = used->ring[used_idx].id;
        uint32_t total_len = used->ring[used_idx].len;

        // 1. 读取 virtio_net_hdr_mrg_rxbuf (包含 num_buffers 字段)
        struct virtio_net_hdr_mrg_rxbuf *hdr =
            (struct virtio_net_hdr_mrg_rxbuf *)
            vq->vq_descx[desc_idx].cookie;

        uint16_t num_buffers = hdr->num_buffers;  // 此包占用的 buffer 数

        // 2. 沿 descriptor chain 遍历，构建 mbuf chain
        struct rte_mbuf *head = NULL;
        struct rte_mbuf *last = NULL;
        uint16_t remain = num_buffers;
        uint16_t cur_idx = desc_idx;

        while (remain > 0) {
            struct rte_mbuf *mbuf =
                (struct rte_mbuf *)vq->vq_descx[cur_idx].cookie;

            // 跳过 header buffer，从数据 buffer 开始
            if (remain == num_buffers) {
                // 第一个 buffer: 包含 header + 可能的数据
                cur_idx = desc[cur_idx].next;
                remain--;
                continue;
            }

            // 设置数据长度
            uint16_t data_len = RTE_MIN(desc[cur_idx].len,
                                         total_len);
            rte_pktmbuf_data_len(mbuf) = data_len;

            // 链入 mbuf chain
            if (head == NULL)
                head = mbuf;
            else
                last->next = mbuf;
            last = mbuf;

            total_len -= data_len;
            cur_idx = desc[cur_idx].next;
            remain--;
        }

        // 3. 设置 head mbuf 的总长度
        if (head) {
            rte_pktmbuf_pkt_len(head) = used->ring[used_idx].len;
            head->nb_segs = num_buffers - 1;
            rx_pkts[nb_recv++] = head;
        }

        // 4. 释放所有 descriptor 回 free chain
        // ...

        vq->vq_used_cons_idx++;
    }

    return nb_recv;
}
```

## 8. Scatter-Gather (分散聚集)

### 8.1 TX 方向的 Descriptor Chain

TX 时，如果一个 `rte_mbuf` 是多 segment，也就是：

```text
mbuf_head -> seg1 -> seg2 -> ...
nb_segs > 1
```

virtio PMD 不能假设 packet data 是一段连续内存。它要把每个 segment 映射成一个
virtio descriptor，并用 `VRING_DESC_F_NEXT` 串成 descriptor chain。

映射规则：

```text
virtio net header -> 1 个 descriptor
mbuf segment 0    -> 1 个 descriptor
mbuf segment 1    -> 1 个 descriptor
mbuf segment 2    -> 1 个 descriptor
...
```

也就是：

```text
descriptor 数量 = 1 个 virtio_net_hdr + mbuf->nb_segs
```

```
┌─────────────────────────────────────────────────────────────┐
│            TX Scatter-Gather (多 segment mbuf)               │
│                                                              │
│  mbuf: nb_segs = 3, pkt_len = 1500                          │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐                  │
│  │ seg 0   │──→│ seg 1   │──→│ seg 2   │                  │
│  │ 128B    │   │ 512B    │   │ 860B    │                  │
│  │ header  │   │ data    │   │ data    │                  │
│  └─────────┘   └─────────┘   └─────────┘                  │
│                                                              │
│  映射到 descriptor chain:                                   │
│  ┌─────────┐   ┌─────────┐   ┌─────────┐   ┌─────────┐    │
│  │ Desc H  │──→│ Desc 0  │──→│ Desc 1  │──→│ Desc 2  │    │
│  │virtio   │   │ 128B    │   │ 512B    │   │ 860B    │    │
│  │net hdr  │   │ flags=N │   │ flags=N │   │ flags=0 │    │
│  │ flags=N │   │         │   │         │   │ (末尾)   │    │
│  └─────────┘   └─────────┘   └─────────┘   └─────────┘    │
│                                                              │
│  注意: TX 方向的 descriptor 没有 VRING_DESC_F_WRITE flag      │
│  (WRITE 表示 Host 写入，TX 是 Guest → Host，不需要)         │
└─────────────────────────────────────────────────────────────┘
```

上图中的对应关系是：

| mbuf 内容         | virtio descriptor | descriptor addr 指向什么 | flags               |
| ----------------- | ----------------- | ------------------------ | ------------------- |
| virtio net header | Desc H            | `struct virtio_net_hdr`  | `VRING_DESC_F_NEXT` |
| `seg0`            | Desc 0            | `rte_pktmbuf_mtod(seg0)` | `VRING_DESC_F_NEXT` |
| `seg1`            | Desc 1            | `rte_pktmbuf_mtod(seg1)` | `VRING_DESC_F_NEXT` |
| `seg2`            | Desc 2            | `rte_pktmbuf_mtod(seg2)` | 0，表示 chain 结束  |

TX 方向没有 `VRING_DESC_F_WRITE`，因为数据方向是 Guest -> Host。Host 只需要读取
这些 descriptor 指向的数据，然后发送出去。

简化伪代码：

```c
// 先放 virtio net header
desc[h].addr = virtio_hdr_iova;
desc[h].len = sizeof(struct virtio_net_hdr);
desc[h].flags = VRING_DESC_F_NEXT;
desc[h].next = first_data_desc;

// 再把每个 mbuf segment 映射成一个 descriptor
for (seg = m; seg != NULL; seg = seg->next) {
    desc[d].addr = rte_mbuf_data_iova(seg);
    desc[d].len = rte_pktmbuf_data_len(seg);

    if (seg->next != NULL) {
        desc[d].flags = VRING_DESC_F_NEXT;
        desc[d].next = next_desc;
    } else {
        desc[d].flags = 0;  // 最后一个 descriptor
    }
}
```

Host/vhost 后端看到的是一条 descriptor chain。它不要求 packet data 在 Guest 内存中
连续，只要按 chain 顺序读取每个 descriptor 指向的内存，就能重建完整 packet：

```text
完整 packet = Desc 0 data + Desc 1 data + Desc 2 data + ...
```

## 9. 性能优化

### 9.1 Free Chain 管理

```
┌─────────────────────────────────────────────────────────────┐
│              Descriptor Free Chain                           │
│                                                              │
│  初始状态 (256 个 descriptor):                               │
│  vq_desc_head_idx → 0 → 1 → 2 → ... → 255 → END            │
│  vq_free_cnt = 256                                           │
│                                                              │
│  分配一个 descriptor:                                       │
│  head = 0;                                                   │
│  vq_desc_head_idx = desc[0].next = 1;                       │
│  vq_free_cnt = 255;                                          │
│                                                              │
│  归还一个 descriptor:                                       │
│  desc[last].next = returned_idx;                             │
│  vq_free_cnt++;                                              │
│                                                              │
│  优势: O(1) 分配和归还，无需遍历                            │
└─────────────────────────────────────────────────────────────┘
```

### 9.2 Kick 优化

Kick 不是 CPU 异常，也不是普通 Unix signal。它是 virtio 的设备通知机制：
Guest 把 descriptor 放进 available ring 后，通过一次设备通知告诉 Host
"队列里有新 descriptor 了"。

不同后端的通知路径不同：

| 场景        | Guest -> Host kick 的形式                                                                      |
| ----------- | ---------------------------------------------------------------------------------------------- |
| virtio PCI  | Guest 写 PCI notify BAR / queue notify 寄存器                                                  |
| virtio MMIO | Guest 写 MMIO QueueNotify 寄存器                                                               |
| vhost-net   | notify 写入经 QEMU/ioeventfd 转成 Host kernel vhost 事件                                       |
| vhost-user  | Guest 写 notify 地址先被 KVM 捕获；KVM 匹配 ioeventfd 后 signal kickfd，用户态后端 poll 到事件 |

在 vhost-user 场景里，常见的是：

```
Guest virtio PMD
  -> 更新 avail ring
  -> 写 virtio notify register/MMIO 地址
  -> VM-Exit 到 KVM
  -> KVM 发现该地址注册了 ioeventfd
  -> KVM signal 对应的 eventfd
  -> Host vhost-user backend 的 kickfd 可读
  -> 后端处理 virtqueue
```

如果没有 `ioeventfd`，这次 MMIO/PIO 写通常会变成 `KVM_EXIT_MMIO` /
`KVM_EXIT_IO` 返回给 QEMU，由 QEMU 设备模型处理。`ioeventfd` 的优化点是：
**仍然由 KVM 捕获 notify 写，但不再每次都回到 QEMU 主循环**。

#### kick eventfd 的原理

`eventfd` 是 Linux 提供的轻量事件通知 fd。可以把它理解成一个内核里的计数器：

```text
write(eventfd):
  counter += value
  唤醒 poll/epoll 等待者

read(eventfd):
  读取并清空 counter
```

vhost-user 场景里，每个 virtqueue 通常会有一个 **kickfd**：

```text
kickfd = Guest -> Host 通知
callfd = Host -> Guest 通知
```

kickfd 的建立过程：

```text
QEMU
  -> 创建 eventfd，作为某个 virtqueue 的 kickfd
  -> 通过 KVM_IOEVENTFD 告诉 KVM：
       Guest 如果写 virtio notify 地址，就 signal 这个 eventfd
  -> 通过 vhost-user 协议把这个 eventfd fd 传给用户态后端
       VHOST_USER_SET_VRING_KICK

vhost-user backend
  -> epoll/poll 这个 kickfd
  -> kickfd 可读时，说明 Guest 对该 virtqueue 做了 notify
```

运行时路径：

```text
Guest virtio PMD
  -> 把 descriptor 放进 avail ring
  -> 写 virtio notify register/MMIO 地址
       例如：通知 queue 0 有新 descriptor
  -> CPU VM-Exit 到 KVM
  -> KVM 匹配 ioeventfd 规则
  -> KVM eventfd_signal(kickfd)
  -> vhost-user backend epoll 被唤醒
  -> backend read(kickfd)
  -> backend 读取 avail ring，处理 descriptor
```

没有 kick eventfd 时，路径更重：

```text
Guest 写 notify
  -> VM-Exit 到 KVM
  -> KVM_EXIT_MMIO / KVM_EXIT_IO 返回给 QEMU
  -> QEMU 主循环处理 virtio notify
  -> QEMU 再通知 vhost 后端或自己处理 virtqueue
```

有 kick eventfd 后：

```text
Guest 写 notify
  -> VM-Exit 到 KVM
  -> KVM 直接 signal eventfd
  -> vhost 后端直接醒来处理 virtqueue
```

它解决的问题是：

| 问题                         | kick eventfd 的作用                                 |
| ---------------------------- | --------------------------------------------------- |
| 每次 kick 都进入 QEMU 主循环 | KVM 直接 signal eventfd，绕过 QEMU 设备模型热路径   |
| QEMU 成为数据面瓶颈          | vhost-user 后端直接处理 virtqueue                   |
| 多一次用户态调度和锁竞争     | 减少 KVM -> QEMU -> backend 的中转                  |
| 后端阻塞等待新 descriptor    | backend 可以 epoll kickfd，被 Guest notify 精准唤醒 |

注意：kick eventfd **没有消除 VM-Exit 本身**。Guest 写 notify 地址仍然会被 KVM
捕获。它优化的是 VM-Exit 之后的处理路径：让 KVM 在内核里完成事件转发，而不是把
每一次数据面 kick 都交给 QEMU 用户态设备模型。

如果 vhost 后端本身在 busy polling virtqueue，kickfd 的唤醒价值会下降；但在
阻塞等待、低流量、控制面切换、或不想让后端线程一直满核空转的场景中，kickfd
仍然是关键机制。

epoll 能告诉后端的是 **哪个 kickfd 可读**，也就是哪个 VM 的哪个 virtqueue
被 Guest notify 了。它不会告诉后端具体新增了几个 descriptor，也不会直接给出
descriptor 内容。后端醒来后仍然要读取该 virtqueue 的 available ring：

```text
epoll 返回 kickfd(queue 3) 可读
  -> read(kickfd) 清事件计数
  -> 读取 queue 3 的 avail.idx
  -> 从上次处理位置继续消费 descriptor
```

所以 kickfd/epoll 解决的是"不用在空闲时遍历所有 virtqueue 等事件"；
真正的数据仍然来自共享内存中的 virtqueue。

反方向也有通知：Host 处理完 descriptor 后更新 used ring，如果 Guest 需要通知，
Host 会通过 callfd / interrupt 通知 Guest。但 DPDK virtio PMD 通常运行在轮询模式，
更多时候直接轮询 used ring，避免依赖中断。

```c
// 不是每次 enqueue 都需要 kick
// DPDK 使用 event suppression 机制减少 kick 次数

// Guest 设置 avail.flags = VIRTIO_AVAIL_F_NO_INTERRUPT
// → 告诉 Host: "我不需要中断通知"
//
// Guest 设置 used_event = avail.idx - N
// → 告诉 Host: "直到 Used Ring 消费到这个位置，不用通知我"
//
// Host 设置 used.flags = VIRTIO_USED_F_NO_NOTIFY
// → 告诉 Guest: "不用每次都 kick 我，攒一批再说"
//
// Host 设置 avail_event = used.idx + N
// → 告诉 Guest: "直到 Available Ring 推进到这个位置，不用 kick 我"

// DPDK 的 virtqueue_notify() 内部检查是否需要 kick:
static inline void
virtqueue_notify(struct virtqueue *vq)
{
    // 通过 notify_addr 写入触发 Host 通知
    // 具体实现取决于 virtio 设备类型 (PCI / MMIO / user)
    // 内部会检查 VIRTIO_USED_F_NO_NOTIFY 是否设置
    vq->hw->notify_queue(vq);
}
```

### 9.3 轮询模式

```c
// DPDK 典型使用方式: 轮询模式 (Poll Mode)

// 1. 配置时不启用中断
struct rte_eth_conf conf = {
    .intr_conf = {
        .rxq = 0,  // 不启用 RX 中断
    },
};

// 2. 应用层轮询 (无需等待中断)
while (!force_quit) {
    // RX: 轮询 Used Ring
    uint16_t nb_rx = rte_eth_rx_burst(port_id, queue_id, pkts, BURST_SIZE);

    // TX: 轮询发送 + cleanup
    virtio_xmit_cleanup(vq, BURST_SIZE);  // 先回收已发送的
    uint16_t nb_tx = rte_eth_tx_burst(port_id, queue_id, pkts, nb_rx);
}

// 优势: 避免 VM exit / interrupt 开销
// 劣势: CPU 100% 占用 (适合 DPDK 高吞吐场景)
```

## 10. 总结

Virtio 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    Virtio 数据路径                            │
│                                                              │
│  Guest OS                                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ virtio-net driver (DPDK Virtio PMD)                  │  │
│  │                                                       │  │
│  │  TX: mbuf → Desc Chain → Available Ring → Kick      │  │
│  │  RX: Used Ring → Desc Chain → mbuf → Refill Avail   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  Virtqueue (shared memory: desc + avail + used)             │
│                            ↓                                │
│  Host (QEMU / VPP / vhost-user / SPDK)                      │
└─────────────────────────────────────────────────────────────┘
```

关键特性：

| 特性               | 说明                                                                 |
| ------------------ | -------------------------------------------------------------------- |
| **Virtqueue**      | Descriptor Table + Available Ring + Used Ring 三部分                 |
| **Refill**         | Guest 提前提供空闲缓冲区到 Available Ring，Host 填充后放入 Used Ring |
| **多队列**         | VIRTIO_NET_F_MQ，RSS 分散负载到多个 queue pair                       |
| **Mergeable RX**   | VIRTIO_NET_F_MRG_RXBUF，大包拆成多个 descriptor，用 mbuf chain 组装  |
| **Scatter-Gather** | TX 多 segment mbuf 映射到 descriptor chain                           |
| **Kick 优化**      | Event suppression 减少 VM exit 次数                                  |
| **vhost-user**     | 用户态 Host 后端，性能最高 (详见 VDPA 章节)                          |

---

## 参考资源

- [Virtio 1.1 规范](https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html)
- [DPDK virtio PMD 文档](https://doc.dpdk.org/guides/nics/virtio.html)
- DPDK 源码: `drivers/net/virtio/virtqueue.h`, `virtio_ring.h`, `virtio_rxtx.c`
