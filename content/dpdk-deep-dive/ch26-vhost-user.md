---
title: "DPDK 深度探索 ch26：vhost-user 原理"
date: 2026-04-10 08:30:00
tags: [dpdk, vhost, vhost-user, virtio, unix-socket, shared-memory, vm]
description: "深入解析 DPDK vhost-user：协议交互、Unix Socket、共享内存映射、Virtqueue 同步"
---

# DPDK 深度探索 ch26：vhost-user 原理

> [!abstract] 核心要点
> vhost-user 是 vhost 协议的用户态实现，允许 QEMU 与 DPDK 应用共享 virtqueue。本章深入解析协议、Socket 通信、内存映射与同步机制。
>
> 如果想先用一个最小实验观察 OVS-DPDK、QEMU、vhost-user socket 和 Guest
> `virtio-net` 的关系，可以看：
> [[ch16a-ovs-dpdk-vhost-user-lab|第十六章补充：OVS-DPDK 与 vhost-user 最小实战]]。

## 1. vhost-user 概述

### 1.1 为什么需要 vhost-user

```
vhost-net vs vhost-user：

vhost-net (kernel):
  QEMU → vhost-net (kernel module) → Tap → NIC
                   ↑
              仍需 kernel 参与

vhost-user (DPDK):
  QEMU → vhost-user (DPDK app) → NIC
                   ↑
             完全用户态

性能对比：
  - vhost-net: ~5-8 Gbps, ~50-80μs latency
  - vhost-user: ~10-15 Gbps, ~20-30μs latency
```

### 1.2 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 架构                          │
│                                                              │
│  Guest VM                                                    │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  Guest Driver / Guest DPDK                           │    │
│  │  - virtio-net kernel driver                          │    │
│  │  - or DPDK virtio PMD                                │    │
│  │                                                       │    │
│  │  TX/RX virtqueue 位于 Guest memory                    │    │
│  └──────────────────────────┬───────────────────────────┘    │
│                             │                                │
│                             │ virtio PCI/MMIO notify         │
│                             ▼                                │
│  QEMU + KVM                                                   │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  QEMU virtio device model                            │    │
│  │  - 创建 virtio-net PCI 设备                          │    │
│  │  - 协商 feature                                      │    │
│  │  - 将 Guest memory table / vring / eventfd 传给后端  │    │
│  │                                                       │    │
│  │  KVM                                                 │    │
│  │  - 运行 vCPU                                         │    │
│  │  - 处理 notify MMIO/PIO + ioeventfd                  │    │
│  └──────────────────────────┬───────────────────────────┘    │
│                             │                                │
│                             │ vhost-user Unix socket         │
│                             │ 控制面消息 + fd 传递            │
│                             ▼                                │
│  Host vhost-user backend                                      │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  DPDK / OVS-DPDK / VPP / SPDK                        │    │
│  │  - mmap Guest memory                                 │    │
│  │  - GPA -> HVA 转换                                   │    │
│  │  - 访问 virtqueue                                    │    │
│  │  - 处理 packet / block request                       │    │
│  │  - 连接 Host NIC PMD / vSwitch / storage backend     │    │
│  └──────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

注意：`vhost-user backend` 通常不在 QEMU 里面。QEMU 负责创建 Guest 看到的
virtio 设备，并通过 vhost-user socket 把 Guest memory、vring 地址、kickfd/callfd
交给外部 backend。真正的数据面 backend 是 socket 另一端的 DPDK、OVS-DPDK、
VPP 或 SPDK 进程。

这里的 `virtio-net` 不是一个额外的交换模块，而是 Guest 前端驱动和 Host 后端共同
遵守的虚拟网卡设备协议：

```text
Guest 前端:
  virtio-net kernel driver
  or DPDK virtio PMD

Host 后端:
  vhost-user backend
  OVS-DPDK / VPP / SPDK / DPDK app

共同协议:
  virtio-net feature bits
  virtio_net_hdr
  RX/TX virtqueue
  descriptor / avail ring / used ring
```

Guest 必须看到一个具体的虚拟 PCI/MMIO 设备，才能枚举设备、加载驱动、协商 feature、
配置 queue。这个设备模型就是 QEMU 提供的 `virtio-net`。vhost-user 把它的数据面
交给外部 backend，但不取消 Guest 侧的 virtio-net 设备语义。

### 1.3 最常见的云主机网络架构

普通云主机通常不是 Guest DPDK 场景，而是 Guest 使用 Linux 内核里的
`virtio-net` driver。应用仍然使用普通 socket，包会经过 Guest kernel 网络栈。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        普通云主机 virtio-net 网络路径                       │
│                                                                             │
│  Guest VM                                                                   │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Application                                                        │    │
│  │  nginx / ssh / database / app server                                │    │
│  │       │                                                             │    │
│  │       │ socket API                                                  │    │
│  │       ▼                                                             │    │
│  │  Guest Linux Network Stack                                          │    │
│  │  TCP/IP / routing / iptables / nftables / qdisc                     │    │
│  │       │                                                             │    │
│  │       ▼                                                             │    │
│  │  virtio-net kernel driver                                           │    │
│  │  - 使用 RX/TX virtqueue                                             │    │
│  │  - 收发普通 skb                                                     │    │
│  └───────┬─────────────────────────────────────────────────────────────┘    │
│          │ virtqueue in Guest memory                                        │
│          │ notify / interrupt / eventfd                                     │
│          ▼                                                                  │
│  QEMU + KVM                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  QEMU virtio-net device model                                       │    │
│  │  - PCI 设备枚举                                                     │    │
│  │  - feature 协商                                                     │    │
│  │  - queue 配置                                                       │    │
│  │                                                                     │    │
│  │  数据面后端通常是：                                                  │    │
│  │  - vhost-net: Host kernel 处理 virtqueue                            │    │
│  │  - vhost-user: OVS-DPDK/VPP 等用户态后端处理 virtqueue              │    │
│  └───────┬─────────────────────────────────────────────────────────────┘    │
│          │                                                                  │
│          ▼                                                                  │
│  Host Virtual Switch / Datapath                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  Linux bridge / OVS kernel / OVN / OVS-DPDK / VPP                   │    │
│  │  - 二层转发                                                         │    │
│  │  - 安全组 / ACL                                                     │    │
│  │  - 路由 / NAT                                                       │    │
│  │  - VXLAN/Geneve tunnel encap/decap                                  │    │
│  │  - output: another VM / tunnel / physical NIC                       │    │
│  └───────┬─────────────────────────────────────────────────────────────┘    │
│          │                                                                  │
│          ▼                                                                  │
│  Physical NIC                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │  ToR switch / underlay network / other compute node                 │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

这条路径里的核心分工：

| 层次              | 作用                                                 |
| ----------------- | ---------------------------------------------------- |
| Guest application | 使用普通 socket，不感知 virtio/vhost                 |
| Guest kernel      | 处理 TCP/IP、路由、防火墙、skb                       |
| virtio-net driver | Guest 前端驱动，把 skb 映射到 virtqueue              |
| QEMU/KVM          | 提供 virtio-net 设备模型，处理控制面和通知机制       |
| vhost 后端        | 在 Host 侧处理 virtqueue，减少 QEMU 数据面开销       |
| Host vSwitch      | 执行云网络规则，决定包进入哪个 VM、tunnel 或物理端口 |
| Physical NIC      | 连接物理网络或 underlay 网络                         |

对比 Guest DPDK 场景：

```text
普通云主机:
  Guest app -> socket -> Guest kernel -> virtio-net kernel driver -> Host

NFV/高性能 VM:
  Guest DPDK app -> DPDK virtio PMD -> virtqueue -> Host
```

所以最常见的云主机网络不是 Guest DPDK，而是 `virtio-net kernel driver +
Host vSwitch/vhost`。

> [!tip] 延伸阅读
> 如果想从商业和架构视角理解为什么会有 vhost-user、OVS-DPDK、Guest DPDK、
> SR-IOV 这些方案，可以继续看：
> [[2026-05-26-nfv-network-functions-virtualization|NFV 深入理解：网络功能虚拟化的商业逻辑与技术架构]]

## 2. vhost-user 协议

### 2.1 消息类型

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 消息                          │
│                                                              │
│  功能协商：                                                  │
│  - VHOST_USER_GET_FEATURES                               │
│  - VHOST_USER_SET_FEATURES                               │
│  - VHOST_USER_GET_PROTOCOL_FEATURES                      │
│  - VHOST_USER_SET_PROTOCOL_FEATURES                      │
│                                                              │
│  内存管理：                                                  │
│  - VHOST_USER_SET_MEM_TABLE                              │
│  - VHOST_USER_SET_LOG_BASE                              │
│                                                              │
│  Virtqueue：                                               │
│  - VHOST_USER_SET_VRING_KICK                             │
│  - VHOST_USER_SET_VRING_CALL                            │
│  - VHOST_USER_SET_VRING_ERR                             │
│  - VHOST_USER_GET_VRING_BASE                            │
│                                                              │
│  连接管理：                                                  │
│  - VHOST_USER_GET_QUEUE_NUM                              │
│  - VHOST_USER_SET_OWNER                                  │
│  - VHOST_USER_RESET_OWNER                                │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 消息格式

```c
// vhost-user 消息头
typedef struct {
    uint32_t request;        // 消息类型
    uint32_t flags;          // 版本和标志 (VERSION | REPLY | NEED_REPLY)
    uint64_t size;           // 负载大小
} __attribute__((packed)) vhost_user_msg_t;

// Request types
enum {
    VHOST_USER_NONE = 0,
    VHOST_USER_GET_FEATURES = 1,
    VHOST_USER_SET_FEATURES = 2,
    VHOST_USER_SET_MEM_TABLE = 3,
    VHOST_USER_SET_VRING_KICK = 4,
    VHOST_USER_SET_VRING_CALL = 5,
    VHOST_USER_SET_VRING_ERR = 6,
    // ...
};

// Flags
#define VHOST_USER_VERSION_MASK     0x3
#define VHOST_USER_REPLY_MASK      (1 << 2)
#define VHOST_USER_NEED_ASYNC      (1 << 3)
```

### 2.3 典型握手流程

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 连接流程                      │
│                                                              │
│  QEMU                               DPDK App                 │
│   │                                    │                     │
│   │ --- connect() -------------------> │                     │
│   │                                    │                     │
│   │  <-- version negotiation ----------│                     │
│   │                                    │                     │
│   │  --- SET_FEATURES ---------------> │                     │
│   │  --- SET_PROTOCOL_FEATURES ------> │                     │
│   │                                    │                     │
│   │  --- SET_MEM_TABLE --------------> │  (共享内存)          │
│   │                                    │                     │
│   │  --- SET_VRING_KICK -------------> │  (TX virtqueue)     │
│   │  --- SET_VRING_CALL -------------> │  (RX virtqueue)     │
│   │                                    │                     │
│   │  ============= 数据路径 ==============                   │
│   │                                    │                     │
└─────────────────────────────────────────────────────────────┘
```

## 3. Unix Socket 通信

### 3.1 Socket 创建

```c
// vhost-user socket server
static int
vhost_user_start_server(const char *path)
{
    int fd;
    struct sockaddr_un un;

    // 创建 socket
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
        return -1;

    // 绑定路径
    un.sun_family = AF_UNIX;
    strncpy(un.sun_path, path, sizeof(un.sun_path) - 1);
    unlink(path);  // 删除旧的

    bind(fd, (struct sockaddr *)&un, sizeof(un));
    listen(fd, 32);

    return fd;
}
```

### 3.2 消息接收

```c
// 接收 vhost-user 消息
static int
vhost_user_recv_msg(int conn_fd, vhost_user_msg_t *msg)
{
    // 接收消息头
    char buf[sizeof(vhost_user_msg_t)];
    int ret = recv(conn_fd, buf, sizeof(buf), MSG_WAITALL);
    if (ret != sizeof(buf))
        return -1;

    memcpy(msg, buf, sizeof(*msg));

    // 接收负载 (如果有)
    if (msg->size > 0) {
        msg->payload = malloc(msg->size);
        ret = recv(conn_fd, msg->payload, msg->size, MSG_WAITALL);
    }

    return 0;
}

// 发送回复
static int
vhost_user_send_reply(int conn_fd, vhost_user_msg_t *msg)
{
    msg->flags |= VHOST_USER_REPLY_MASK;

    // 发送头
    send(conn_fd, msg, sizeof(*msg), 0);

    // 发送负载
    if (msg->size > 0 && msg->payload)
        send(conn_fd, msg->payload, msg->size, 0);

    return 0;
}
```

### 3.3 消息处理

```c
// 消息处理分发
static void
vhost_user_msg_handler(int conn_fd, vhost_user_msg_t *msg)
{
    switch (msg->request) {
    case VHOST_USER_GET_FEATURES:
        msg->payload.u64 = VHOST_FEATURES;
        msg->size = sizeof(uint64_t);
        vhost_user_send_reply(conn_fd, msg);
        break;

    case VHOST_USER_SET_FEATURES:
        device->features = msg->payload.u64;
        break;

    case VHOST_USER_SET_MEM_TABLE:
        vhost_user_set_mem_table(device, msg);
        break;

    case VHOST_USER_SET_VRING_KICK:
        vhost_user_set_vring_kick(device, msg);
        break;

    case VHOST_USER_SET_VRING_CALL:
        vhost_user_set_vring_call(device, msg);
        break;

    default:
        break;
    }
}
```

## 4. 共享内存映射

### 4.1 内存表

```c
// 内存区域
typedef struct {
    uint64_t guest_phys_addr;   // VM 物理地址 (GPA)
    uint64_t memory_size;        // 大小
    uint64_t userspace_addr;     // 用户态地址 (HVA)
    uint64_t mmap_offset;        // mmap 偏移
} vhost_memory_region_t;

// 内存表消息
typedef struct {
    uint32_t nregions;           // 区域数量
    uint32_t padding;
    vhost_memory_region_t regions[];
} vhost_user_memory_t;
```

### 4.2 内存映射

```c
// 设置内存表
static int
vhost_user_set_mem_table(vhost_device_t *dev,
                         vhost_user_msg_t *msg)
{
    vhost_user_memory_t *mem = msg->payload;

    // 映射每个区域
    for (int i = 0; i < mem->nregions; i++) {
        vhost_memory_region_t *reg = &mem->regions[i];

        // 打开 VM 的内存映射文件
        int fd = open("/dev/mem", O_RDWR);
        if (fd < 0)
            fd = open("/proc/self/fd/" + dev->fd, O_RDWR);

        // mmap 到本地地址空间
        void *addr = mmap(NULL,
                         reg->memory_size,
                         PROT_READ | PROT_WRITE,
                         MAP_SHARED,
                         fd,
                         reg->mmap_offset);

        // 保存映射信息
        dev->regions[i].gpa = reg->guest_phys_addr;
        dev->regions[i].hva = addr;
        dev->regions[i].size = reg->memory_size;
    }

    return 0;
}

// GPA → HVA 转换
static void *
gpa_to_hva(vhost_device_t *dev, uint64_t gpa)
{
    for (int i = 0; i < dev->nregions; i++) {
        if (gpa >= dev->regions[i].gpa &&
            gpa < dev->regions[i].gpa + dev->regions[i].size) {
            return dev->regions[i].hva +
                   (gpa - dev->regions[i].gpa);
        }
    }
    return NULL;
}
```

## 5. Virtqueue 同步

### 5.1 访问 Virtqueue

```c
// 获取 Virtqueue 信息
static void
vhost_user_set_vring(vhost_device_t *dev,
                     int index,
                     struct vhost_virtqueue *vq)
{
    // index: 0=TX, 1=RX (或 TX/RX pair)

    // 获取 descriptor 数组
    vq->desc = gpa_to_hva(dev, vq->desc_addr);

    // 获取 available ring
    vq->avail = gpa_to_hva(dev, vq->avail_addr);

    // 获取 used ring
    vq->used = gpa_to_hva(dev, vq->used_addr);

    // 获取队列大小
    vq->size = vq->num;
}

// 获取 available slot
static uint16_t
vhost_user_get_available(vhost_virtqueue_t *vq)
{
    // 返回可用的 descriptor 数量
    uint16_t avail_idx = *(volatile uint16_t *)&vq->avail->idx;
    return avail_idx - vq->used_idx;
}
```

### 5.2 事件通知

```c
// Kick 事件 (Guest → DPDK)
// QEMU 写这个文件描述符通知 DPDK 有新包

static void
vhost_user_kick_handler(int kick_fd, void *arg)
{
    vhost_virtqueue_t *vq = arg;

    // 读取 kick 事件 (可能只是通知，不需要数据)
    uint64_t kick;
    read(kick_fd, &kick, sizeof(kick));

    // 处理可用的 descriptor
    vhost_user_process_tx(vq);
}

// Call 事件 (DPDK → Guest)
// DPDK 写这个文件描述符通知 Guest 有新数据

static void
vhost_user_notify_guest(vhost_virtqueue_t *vq)
{
    // 发送事件
    uint64_t kick = 1;
    write(vq->call_fd, &kick, sizeof(kick));
}
```

## 6. 数据路径

### 6.1 TX 处理 (VM → NIC)

```c
// 处理 VM 发送的包
static uint16_t
vhost_user_tx_burst(vhost_device_t *dev,
                    struct rte_mbuf **mbufs,
                    uint16_t nb)
{
    vhost_virtqueue_t *vq = &dev->vq[0];  // TX queue

    // 获取可用 descriptor
    uint16_t avail = vq->avail->idx - vq->last_used_idx;
    uint16_t nb_to_send = RTE_MIN(avail, nb);

    for (uint16_t i = 0; i < nb_to_send; i++) {
        // 获取 descriptor
        uint16_t desc_idx = vq->avail->ring[
            vq->last_used_idx & (vq->size - 1)];

        // 获取 buffer 地址
        void *data = gpa_to_hva(dev, vq->desc[desc_idx].addr);
        uint32_t len = vq->desc[desc_idx].len;

        // 填充 mbuf
        mbufs[i]->data_len = len;
        rte_memcpy(rte_pktmbuf_mtod(mbufs[i], void *),
                   data, len);

        // 更新 used
        vq->last_used_idx++;
    }

    // 更新 used ring
    *(volatile uint16_t *)&vq->used->idx = vq->last_used_idx;

    // 通知 Guest
    vhost_user_notify_guest(vq);

    return nb_to_send;
}
```

### 6.2 RX 处理 (NIC → VM)

```c
// 准备缓冲区给 VM
static uint16_t
vhost_user_rx_burst(vhost_device_t *dev,
                    struct rte_mbuf **mbufs,
                    uint16_t nb)
{
    vhost_virtqueue_t *vq = &dev->vq[1];  // RX queue

    // 获取可用 descriptor
    uint16_t avail = vq->avail->idx - vq->last_used_idx;
    uint16_t nb_to_recv = RTE_MIN(avail, nb);

    for (uint16_t i = 0; i < nb_to_recv; i++) {
        // 查找空闲 descriptor
        uint16_t desc_idx = vq->last_used_idx & (vq->size - 1);

        // 获取 mbuf
        struct rte_mbuf *mbuf = mbufs[i];

        // 设置 descriptor
        vq->desc[desc_idx].addr = rte_mem_virt2phy(mbuf->buf_addr);
        vq->desc[desc_idx].len = mbuf->buf_len;

        // 添加到 available
        vq->avail->ring[
            vq->avail->idx & (vq->size - 1)] = desc_idx;
        vq->avail->idx++;

        vq->last_used_idx++;
    }

    // 通知 Guest
    vhost_user_notify_guest(vq);

    return nb_to_recv;
}
```

## 7. QEMU 配置

### 7.1 QEMU 命令行

```bash
# QEMU vhost-user 配置
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -enable-kvm \
    -device virtio-net-pci,\
netdev=net0,\
vectors=4 \
    -netdev vhost-user,\
id=net0,\
chardev=char0,\
queues=4 \
    -chardev socket,\
id=char0,\
path=/var/run/vpp/vhost.sock,\
server=on,\
wait=off
```

### 7.2 vhost-user + DPDK

配套实践可以参考仓库里的 `practice/guest_dpdk_virtio/`，里面给了
Host OVS-DPDK vhost-user 端口、QEMU 启动参数、Guest DPDK virtio PMD
绑定和 `testpmd` 验证步骤。

```bash
# VPP 监听 vhost-user socket
vpp# create vhost-user socket /var/run/vpp/vhost.sock

# 查看状态
vpp# show vhost-user

# 示例输出：
# vhost-user0: socket=/var/run/vpp/vhost.sock
#   Features: csum offload, tso, mrg-rxbuf
#   Queues: 4 (TX/RX pairs)
#   State: active
```

## 8. 总结

vhost-user 数据流：

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 数据路径                      │
│                                                              │
│  Guest VM                                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ virtio-net TX → Virtqueue → Available Ring → Kick   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓ mmap                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  DPDK 读取 descriptor → 处理包 → 更新 Used Ring     │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│                         NIC                                 │
└─────────────────────────────────────────────────────────────┘
```

与 vhost-net 对比：

| 特性           | vhost-net     | vhost-user       |
| -------------- | ------------- | ---------------- |
| **Backend**    | Kernel module | Userspace (DPDK) |
| **上下文切换** | Kernel ↔ User | 仅 User          |
| **延迟**       | ~50-80μs      | ~20-30μs         |
| **吞吐量**     | ~8 Gbps       | ~15 Gbps         |
| **灵活性**     | 低            | 高               |

---

## 参考资源

- [QEMU vhost-user](https://qemu.readthedocs.io/en/latest/interop/vhost-user.html)
- [DPDK vhost library](https://doc.dpdk.org/guides/prog_guide/vhost_lib.html)
