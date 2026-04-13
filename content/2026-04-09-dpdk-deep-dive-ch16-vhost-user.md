---
title: "DPDK 深度探索 (十六)：vhost-user 与 virtio 加速"
date: 2026-04-09
tags: [dpdk, series, vhost-user, virtio, VM, shared-memory, virtqueue, zero-copy]
description: "深入理解 vhost-user 与 virtio 加速机制——VM 与 DPDK 的高性能共享内存通信、virtqueue 机制、eventfd 通知、零拷贝实现"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-15. 前十五章已完成
> 16. **第十六章：vhost-user 与 virtio 加速**

---

## 1. 概述：vhost-user vs KNI

### 1.1 为什么需要 vhost-user？

KNI 虽然能让 DPDK 与内核交互，但性能损耗大。vhost-user 则是为高性能 VM 通信设计的：

| 特性 | KNI | vhost-user |
|------|-----|------------|
| **通信对象** | Linux 内核网络栈 | VM (QEMU) |
| **数据路径** | FIFO + ioctl (有拷贝) | 共享内存 + eventfd (零拷贝) |
| **延迟** | 高 (~10-100μs) | 低 (~1-5μs) |
| **吞吐量** | 较低 | 线速 (几乎无开销) |
| **适用场景** | 控制平面、SSH、BGP | 数据平面、存储 |

### 1.2 virtio 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           virtio 架构                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  VM (Guest)                              Host (QEMU + DPDK)                │
│  ┌─────────────────┐                  ┌─────────────────┐                   │
│  │    App          │                  │   App (DPDK)    │                   │
│  └────────┬────────┘                  └────────┬────────┘                   │
│           │                                        │                         │
│           ▼                                        ▼                         │
│  ┌─────────────────┐                  ┌─────────────────┐                   │
│  │  virtio-net    │◄─────────────────►│   vhost-net     │                   │
│  │  driver (guest) │     virtqueue    │   (DPDK)        │                   │
│  └────────┬────────┘                  └────────┬────────┘                   │
│           │                                        │                         │
│           │ 共享内存 (virtqueue)                    │                         │
│           └────────────────────────────────────────┘                         │
│                      ▲                                                      │
│                      │                                                      │
│               ┌──────┴───────┐                                            │
│               │   VM Memory   │                                            │
│               │  (via QEMU)  │                                            │
│               └──────────────┘                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. virtio 机制

### 2.1 virtqueue 结构

```c
// virtqueue 是共享内存中的环形缓冲区
// 每个 virtio-net 设备有两个 virtqueue：
// - 发送队列 (TX): VM → Host
// - 接收队列 (RX): Host → VM

struct virtqueue {
    // 描述符表 (Descriptor Table)
    // 每个描述符指向一个数据缓冲区
    struct vring_desc *desc;      // Guest 物理地址

    // 可用环 (Available Ring)
    // Host 写入，Guest 读取
    struct vring_avail *avail;   // Guest 物理地址

    // 已用环 (Used Ring)
    // Guest 写入，Host 读取
    struct vring_used *used;      // Guest 物理地址

    // 队列大小
    uint16_t size;

    // 索引
    uint16_t idx;  // 下次要用的 desc 索引
};

// vring_desc - 描述符
struct vring_desc {
    rte_le64_t addr;    // 缓冲区物理地址 (Guest)
    rte_le32_t len;     // 缓冲区长度
    rte_le16_t flags;   // 标志 (VRING_DESC_F_*)
    rte_le16_t next;    // 下一个描述符索引 (用于链式)
};

// 描述符标志
#define VRING_DESC_F_NEXT       1  // 链式描述符
#define VRING_DESC_F_WRITE      2  // 只写 (设备可写，驱动只读)
#define VRING_DESC_F_INDIRECT   4  // 间接描述符

// vring_avail - 可用环
struct vring_avail {
    rte_le16_t flags;    // 标志
    rte_le16_t idx;      // 下一个要填充的索引
    rte_le16_t ring[];  // 描述符索引数组
};

// vring_used - 已用环
struct vring_used {
    rte_le16_t flags;    // 标志
    rte_le16_t idx;      // 下一个要填充的索引
    struct vring_used_elem {
        rte_le32_t id;   // 使用的描述符索引
        rte_le32_t len;  // 写入的数据长度
    } ring[];
};
```

### 2.2 virtio-net 头部

```c
// virtio-net 头 (在数据前面的控制头)
struct virtio_net_hdr {
    uint8_t flags;       // VIRTIO_NET_HDR_F_*
    uint8_t gso_type;    // VIRTIO_NET_HDR_GSO_*
    rte_le16_t hdr_len;   // 头长度
    rte_le16_t gso_size;  // GSO 分段大小
    rte_le16_t csum_start;
    rte_le16_t csum_offset;
    uint16_t num_buffers; // 合并接收的缓冲片数
};

// 头部标志
#define VIRTIO_NET_HDR_F_NEEDS_CSUM  1  // 需要校验
#define VIRTIO_NET_HDR_F_DATA_VALID   2  // 数据已校验
#define VIRTIO_NET_HDR_F_RSC_INFO     4  // RSC 信息

// GSO 类型
#define VIRTIO_NET_HDR_GSO_NONE       0
#define VIRTIO_NET_HDR_GSO_TCPV4      1
#define VIRTIO_NET_HDR_GSO_TCPV6      2
#define VIRTIO_NET_HDR_GSO_UDP         3
#define VIRTIO_NET_HDR_GSO_TCP_ECN    4
```

### 2.3 发送流程 (VM → Host)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    virtio 发送流程 (VM → Host)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  VM 侧 (virtio-net driver):                                               │
│  ───────────────────────────                                              │
│                                                                             │
│  1. 从 avail 环获取一个 desc                                               │
│     avail->ring[avail->idx % size] → desc_idx                            │
│                                                                             │
│  2. 填充数据到 desc 指向的缓冲区                                           │
│     desc.addr → 数据                                                        │
│     desc.len → 数据长度                                                     │
│                                                                             │
│  3. 将 desc_idx 放入 avail->ring                                          │
│     avail->ring[avail->idx] = desc_idx                                    │
│     avail->idx++                                                          │
│                                                                             │
│  4. 通知 Host (kick)                                                       │
│     Host 通过 eventfd 收到通知                                              │
│                                                                             │
│  Host 侧 (vhost-net):                                                    │
│  ─────────────────────────                                                │
│                                                                             │
│  5. 轮询 avail 环，检查有新 desc                                           │
│     avail->idx - last_avail_idx → 新 desc 数量                            │
│                                                                             │
│  6. 读取 desc，获取数据地址和长度                                          │
│     mbuf = get_mbuf_from_desc(desc)                                      │
│                                                                             │
│  7. 处理数据                                                               │
│                                                                             │
│  8. 将结果放入 used 环                                                     │
│     used->ring[used->idx] = { desc_idx, len }                           │
│     used->idx++                                                           │
│                                                                             │
│  9. 通知 VM (kick via eventfd)                                            │
│     used->flags |= VRING_AVAIL_F_INTERRUPT                              │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. vhost-user 协议

### 3.1 vhost-user 消息类型

```c
// vhost-user 使用 Unix Domain Socket 进行控制平面通信
// 消息格式：vhost_user_msg

enum vhost_user_request {
    VHOST_USER_NONE           = 0,
    VHOST_USER_GET_FEATURES   = 1,
    VHOST_USER_SET_FEATURES   = 2,
    VHOST_USER_SET_OWNER      = 3,
    VHOST_USER_RESET_OWNER    = 4,
    VHOST_USER_SET_MEM_TABLE  = 5,    // 共享内存表
    VHOST_USER_SET_LOG_BASE   = 6,
    VHOST_USER_SET_LOG_FD     = 7,
    VHOST_USER_SET_VRING_KICK = 8,    // 绑定 virtqueue kick fd
    VHOST_USER_SET_VRING_CALL  = 9,    // 绑定 virtqueue call fd
    VHOST_USER_SET_VRING_ERR   = 10,
    VHOST_USER_GET_PROTOCOL_FEATURES = 11,
    VHOST_USER_SET_PROTOCOL_FEATURES = 12,
    VHOST_USER_GET_QUEUE_NUM   = 13,
    VHOST_USER_SET_VRING_ENABLE = 14,
    VHOST_USER_SEND_RARP       = 15,
};

// 消息头
struct vhost_user_msg {
    vhost_user_request request;  // 请求类型
    uint32_t flags;              // 标志
    uint32_t size;               // 消息体大小
    union {
        // 负载
    } payload;
};
```

### 3.2 主要消息流程

```c
// 1. 获取特性
static int
vhost_user_get_features(int sockfd, uint64_t *features)
{
    struct vhost_user_msg msg = {
        .request = VHOST_USER_GET_FEATURES,
        .flags = VHOST_USER_VERSION,
        .size = 0,
    };

    sendmsg(sockfd, &msg, 0);
    recvmsg(sockfd, &msg, 0);

    *features = msg.payload.u64;
    return 0;
}

// 2. 设置内存表 (关键！共享内存)
static int
vhost_user_set_mem_table(int sockfd, struct vhost_user_ctx *ctx)
{
    struct vhost_user_msg msg;
    int fds[RTE_MAX_MEM_REGIONS];
    int fd_num = 0;

    // 构建内存表
    msg.request = VHOST_USER_SET_MEM_TABLE;
    msg.size = sizeof(ctx->memreg);

    // 填充每个内存区域
    for (int i = 0; i < ctx->nregions; i++) {
        ctx->memreg[i].guest_phys_addr = region[i].gpa;
        ctx->memreg[i].userspace_addr = region[i].hva;
        ctx->memreg[i].memory_size = region[i].size;
        ctx->memreg[i].mmap_offset = region[i].offset;

        // 传递对应的 fd
        fds[fd_num++] = region[i].fd;
    }

    // 发送消息 + fds
    sendmsg_with_fds(sockfd, &msg, fds, fd_num);

    return 0;
}

// 3. 绑定 VRING kick/call fd
static int
vhost_user_set_vring_kick(int sockfd, int index, int fd)
{
    struct vhost_user_msg msg = {
        .request = VHOST_USER_SET_VRING_KICK,
        .flags = VHOST_USER_VERSION,
        .size = sizeof(struct vhost_vring_file),
        .payload.vring_file = {
            .index = index,
            .fd = fd,
        },
    };

    sendmsg(sockfd, &msg, 0);
    return 0;
}

static int
vhost_user_set_vring_call(int sockfd, int index, int fd)
{
    struct vhost_user_msg msg = {
        .request = VHOST_USER_SET_VRING_CALL,
        .flags = VHOST_USER_VERSION,
        .size = sizeof(struct vhost_vring_file),
        .payload.vring_file = {
            .index = index,
            .fd = fd,
        },
    };

    sendmsg(sockfd, &msg, 0);
    return 0;
}
```

### 3.3 共享内存映射

```c
// vhost-user 关键：QEMU 将 VM 内存映射传递给 DPDK
// DPDK 直接访问 VM 内存，无需拷贝

struct vhost_user_memory_region {
    uint64_t guest_phys_addr;   // VM 物理地址
    uint64_t userspace_addr;    // VM 的用户空间地址 (QEMU 映射)
    uint64_t memory_size;       // 区域大小
    uint64_t mmap_offset;       // mmap 偏移
};

struct vhost_user_memory {
    uint32_t nregions;          // 内存区域数
    uint32_t padding;
    struct vhost_user_memory_region regions[];
};
```

---

## 4. DPDK vhost-user 实现

### 4.1 vhost-user 库

```c
// lib/vhost/rte_vhost.h

// vhost-user socket 路径
#define RTE_VHOST_SOCKET_URI    "/var/run/vhost_sockets/%s"

// 连接类型
enum rte_vhostocket_backend {
    VHOST_USER_SOCKET = 0,
    VHOST_USER_VDPA   = 1,
};

// 特性位
#define VIRTIO_F_VERSION_1     32   // virtio 1.0
#define VIRTIO_F_ADMIN_VQ      33   // 管理 virtqueue
#define VIRTIO_F_RING_INDIRECT_DESC 38  // 间接描述符
#define VIRTIO_F_RING_EVENT_IDX 39  // Event_idx

#define VHOST_FEATURES ((1ULL << VIRTIO_F_VERSION_1) | \
                         (1ULL << VIRTIO_F_RING_INDIRECT_DESC) | \
                         (1ULL << VIRTIO_F_RING_EVENT_IDX))

// vhost-user 回调
struct rte_vhost_device_ops {
    // 新连接
    int (*new_connection)(int vid, int sockfd);
    // 连接销毁
    void (*destroy_connection)(int vid);
    // 传输回调
    int (*tx_payload)(int vid, uint16_t qid, struct rte_mbuf *m);
    // 切换队列
    int (*switch_rx_queue)(int vid, uint16_t qid, uint16_t on);
};
```

### 4.2 创建 vhost-user 设备

```c
// 创建 vhost-user socket 并注册回调
int
rte_vhost_driver_register(const char *path, uint64_t flags)
{
    struct vhost_user_socket *vsocket;

    // 分配 socket 结构
    vsocket = calloc(1, sizeof(*vsocket));
    if (!vsocket)
        return -1;

    // 创建 Unix Domain Socket
    vsocket->sockfd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
    if (vsocket->sockfd < 0) {
        free(vsocket);
        return -1;
    }

    // 绑定路径
    unlink(path);  // 删除旧的 socket 文件
    struct sockaddr_un addr = {
        .sun_family = AF_UNIX,
        .sun_path = path,
    };
    bind(vsocket->sockfd, (struct sockaddr *)&addr, sizeof(addr));

    // 监听
    listen(vsocket->sockfd, 32);

    // 保存路径和标志
    strncpy(vsocket->path, path, sizeof(vsocket->path));
    vsocket->flags = flags;

    return 0;
}

// 注册回调
int
rte_vhost_driver_callback_register(const char *path,
                                    struct rte_vhost_device_ops *ops)
{
    struct vhost_user_socket *vsocket = find_socket(path);

    vsocket->ops = ops;
    return 0;
}

// 启动事件循环
int
rte_vhost_driver_start(const char *path)
{
    struct vhost_user_socket *vsocket = find_socket(path);

    // 启动 epoll 监听 socket
    vsocket->epfd = epoll_create1(0);

    struct epoll_event ev = {
        .events = EPOLLIN,
        .data.fd = vsocket->sockfd,
    };
    epoll_ctl(vsocket->epfd, EPOLL_CTL_ADD, vsocket->sockfd, &ev);

    // epoll 循环
    while (1) {
        int nfds = epoll_wait(vsocket->epfd, events, MAX_EVENTS, -1);

        for (int i = 0; i < nfds; i++) {
            if (events[i].data.fd == vsocket->sockfd) {
                // 新连接
                int clientfd = accept(vsocket->sockfd, NULL, NULL);
                handle_new_connection(vsocket, clientfd);
            } else {
                // IO 事件
                handle_io_event(vsocket, events[i].data.fd);
            }
        }
    }

    return 0;
}
```

### 4.3 处理 vhost-user 消息

```c
// 处理 vhost-user 消息
static void
handle_vhost_user_message(int sockfd, struct vhost_user_msg *msg)
{
    switch (msg->request) {
    case VHOST_USER_GET_FEATURES:
        send_reply(sockfd, VHOST_USER_GET_FEATURES, VHOST_FEATURES);
        break;

    case VHOST_USER_SET_FEATURES:
        // 保存 VM 特性
        ctx->features = msg->payload.u64;
        break;

    case VHOST_USER_SET_MEM_TABLE:
        // 映射 VM 内存
        map_memory_regions(ctx, msg->payload.mem_regions,
                          msg->payload.nregions, fds);
        break;

    case VHOST_USER_SET_VRING_KICK:
        // 绑定 kick fd (用于接收 VM 的通知)
        ctx->vring[msg->payload.vring_file.index].kickfd =
            msg->payload.vring_file.fd;
        // 添加到 epoll 监听
        epoll_ctl(ctx->epfd, EPOLL_CTL_ADD,
                  ctx->vring[msg->payload.vring_file.index].kickfd,
                  &ev);
        break;

    case VHOST_USER_SET_VRING_CALL:
        // 绑定 call fd (用于通知 VM)
        ctx->vring[msg->payload.vring_file.index].callfd =
            msg->payload.vring_file.fd;
        break;

    case VHOST_USER_SET_VRING_ENABLE:
        // 启用/禁用队列
        ctx->vring[msg->payload.vring_state.index].enable =
            msg->payload.vring_state.enable;
        break;

    default:
        break;
    }
}
```

---

## 5. 数据路径实现

### 5.1 零拷贝发送 (VM → Host)

```c
// 零拷贝：直接使用 VM 提供的缓冲区，避免拷贝

static uint16_t
vhost_iov_to_mbuf(struct rte_mbuf *m,
                   struct virtio_net_hdr *hdr,
                   struct iovec *iov, int iovcnt)
{
    // 将 VM 的 iovec 直接映射到 mbuf
    m->buf_addr = (void *)iov->iov_base;
    m->buf_iova = vhost_gpa_to_hva(ctx, (uint64_t)iov->iov_base);
    m->pkt_len = iov->iov_len;

    // 复制 virtio-net 头
    rte_memcpy(rte_pktmbuf_mtod(m, void *), hdr, sizeof(*hdr));

    return 0;
}

// 处理 TX virtqueue (VM → Host)
static void
handle_tx_vring(int vid, uint16_t qid)
{
    struct vhost_vring *vring = &ctx->vring[qid];
    uint16_t last_idx = vring->last_avail_idx;

    // 检查可用描述符
    uint16_t avail_idx = vring->avail->idx;

    while (last_idx != avail_idx) {
        // 获取描述符
        uint16_t desc_idx = vring->avail->ring[last_idx & (vring->size - 1)];

        // 解析描述符链
        struct vhost_iov_iter iter;
        struct iovec iov[8];
        int iovcnt = 0;

        parse_desc_chain(vring->desc, desc_idx, iov, &iovcnt, &iter);

        // 获取 virtio-net 头
        struct virtio_net_hdr *hdr = (struct virtio_net_hdr *)iov[0].iov_base;
        iov[0].iov_base = (char *)iov[0].iov_base + sizeof(*hdr);
        iov[0].iov_len -= sizeof(*hdr);
        iter.size -= sizeof(*hdr);

        // 转换为一连串 rte_mbuf
        struct rte_mbuf *m = rte_pktmbuf_alloc(mbuf_pool);
        vhost_iov_to_mbuf(m, hdr, iov, iovcnt);

        // 处理数据（直接使用 VM 内存，无需拷贝）
        process_packet(m);

        // 放入 used 环（通知 VM 释放缓冲区）
        vring->used->ring[vring->used->idx & (vring->size - 1)].id = desc_idx;
        vring->used->ring[vring->used->idx & (vring->size - 1)].len = iter.size;
        vring->used->idx++;

        last_idx++;
    }

    vring->last_avail_idx = last_idx;

    // 通知 VM
    if (vring->callfd >= 0) {
        eventfd_write(vring->callfd, (eventfd_t)1);
    }
}
```

### 5.2 零拷贝接收 (Host → VM)

```c
// 处理 RX virtqueue (Host → VM)

static uint16_t
vhost_mbuf_to_iov(struct rte_mbuf *m, struct iovec *iov)
{
    // 将 mbuf 数据转换为 iovec 供 VM 使用
    iov->iov_base = rte_pktmbuf_mtod(m, void *);
    iov->iov_len = m->pkt_len;

    return 1;
}

// 处理 RX virtqueue
static uint16_t
handle_rx_vring(int vid, uint16_t qid, struct rte_mbuf **mbufs, uint16_t nb_mbufs)
{
    struct vhost_vring *vring = &ctx->vring[qid];
    uint16_t nb_sent = 0;

    for (int i = 0; i < nb_mbufs; i++) {
        // 检查可用描述符
        uint16_t avail_idx = vring->avail->idx;
        uint16_t next_idx = (vring->last_avail_idx + 1) & (vring->size - 1);

        if (next_idx == avail_idx) {
            // 队列满
            break;
        }

        // 获取描述符
        uint16_t desc_idx = vring->avail->ring[vring->last_avail_idx &
                                               (vring->size - 1)];

        // 获取 VM 缓冲区地址
        uint64_t gpa = vring->desc[desc_idx].addr;
        void *hva = vhost_gpa_to_hva(ctx, gpa);
        uint32_t len = vring->desc[desc_idx].len;

        // 填充 VM 缓冲区
        struct virtio_net_hdr *hdr = (struct virtio_net_hdr *)hva;
        memset(hdr, 0, sizeof(*hdr));

        // 直接拷贝数据（这是唯一需要拷贝的地方）
        rte_memcpy(hdr + 1, rte_pktmbuf_mtod(mbufs[i], void *),
                   mbufs[i]->pkt_len);

        // 放入 used 环
        vring->used->ring[vring->used->idx & (vring->size - 1)].id = desc_idx;
        vring->used->ring[vring->used->idx & (vring->size - 1)].len =
            sizeof(*hdr) + mbufs[i]->pkt_len;
        vring->used->idx++;

        rte_pktmbuf_free(mbufs[i]);
        nb_sent++;
    }

    vring->last_avail_idx += nb_sent;

    // 通知 VM
    if (vring->callfd >= 0) {
        eventfd_write(vring->callfd, (eventfd_t)1);
    }

    return nb_sent;
}
```

---

## 6. vhost-user vs vhost-net

| 特性 | vhost-user | vhost-net (kernel) |
|------|------------|-------------------|
| **后端** | 用户态 (DPDK) | 内核模块 |
| **通信方式** | Unix Domain Socket | /dev/vhost-net |
| **数据路径** | 零拷贝（共享内存） | 需要拷贝 |
| **控制路径** | QEMU ↔ DPDK (socket) | QEMU ↔ kernel ↔ DPDK |
| **灵活性** | 高（可自定义协议） | 低 |
| **性能** | 最高 | 较高 |
| **依赖** | QEMU + DPDK | kernel 模块 + QEMU |

---

## 7. 完整示例

### 7.1 vhost-user 交换机

```c
// vhost-user 网桥示例：连接多个 VM 和物理端口

struct vhost_switch {
    int vhost_sock;           // vhost-user socket
    uint16_t port_id;         // 物理端口
    struct rte_mempool *mbuf_pool;
};

static void
vhost_switch_rx(struct vhost_switch *sw)
{
    struct rte_mbuf *mbufs[32];

    // 从物理端口接收
    uint16_t nb_rx = rte_eth_rx_burst(sw->port_id, 0, mbufs, 32);

    // 转发到所有连接的 VM
    for (int qid = 0; qid < sw->nb_queues; qid++) {
        if (sw->vring[qid].enable) {
            handle_rx_vring(sw->vid, qid, mbufs, nb_rx);
        }
    }
}

static void
vhost_switch_tx(struct vhost_switch *sw)
{
    // 处理每个 VM 的 TX virtqueue
    for (int qid = 0; qid < sw->nb_queues; qid++) {
        if (sw->vring[qid].kickfd >= 0) {
            // 检查是否有 VM 发来的数据
            if (poll_fd(sw->vring[qid].kickfd)) {
                handle_tx_vring(sw->vid, qid);
            }
        }
    }
}

static void
vhost_switch_poll(struct vhost_switch *sw)
{
    struct pollfd pfd[MAX_VHOST_PORTS];
    int nfds = 0;

    // 添加物理端口
    pfd[nfds].fd = sw->物理端口中断fd;  // 或轮询
    pfd[nfds++].events = POLLIN;

    // 添加所有 VM 的 kick fd
    for (int i = 0; i < sw->nb_queues; i++) {
        if (sw->vring[i].kickfd >= 0) {
            pfd[nfds].fd = sw->vring[i].kickfd;
            pfd[nfds++].events = POLLIN;
        }
    }

    while (1) {
        poll(pfd, nfds, 1000);  // 1s timeout

        // 处理事件
        if (pfd[0].revents & POLLIN) {
            vhost_switch_rx(sw);
        }

        for (int i = 1; i < nfds; i++) {
            if (pfd[i].revents & POLLIN) {
                int qid = find_vring_by_kickfd(pfd[i].fd);
                handle_tx_vring(sw->vid, qid);
            }
        }
    }
}
```

---

## 8. 小结

本章核心要点：

1. **vhost-user vs KNI**：vhost-user 用于 VM 高性能通信（零拷贝），KNI 用于内核栈交互（控制平面）。

2. **virtqueue 结构**：desc 描述符表 + avail 可用环 + used 已用环，三者构成共享内存环形缓冲区。

3. **virtio-net 头**：紧跟在数据前的控制头，包含 flags、gso_type、checksum 信息。

4. **发送流程**：VM 填充 desc → 放入 avail 环 → kick Host → Host 读取 desc 处理 → 放入 used 环 → kick VM。

5. **vhost-user 协议**：通过 Unix Domain Socket 传递控制消息（GET/SET_FEATURES、SET_MEM_TABLE、SET_VRING_KICK/CALL）。

6. **共享内存映射**：QEMU 将 VM 内存区域通过 fd 传递给 DPDK，DPDK 直接访问（零拷贝关键）。

7. **零拷贝原理**：发送时直接使用 VM 提供的缓冲区（mbuf → iovec），接收时直接填充 VM 缓冲区（mbuf → VM 内存）。

8. **eventfd 通知**：kick fd（VM→Host 通知）、call fd（Host→VM 通知），替代 ioctl。

9. **vhost-user 特性**：VIRTIO_F_VERSION_1、VIRTIO_F_RING_INDIRECT_DESC、VIRTIO_F_RING_EVENT_IDX。

10. **应用场景**：vhost-user 网桥（连接 VM 和物理端口）、存储加速（vhost-scsi）、VDPA（ virtio-blk / virtio-net）。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch17-vhost-scsi|第十七章]]将讲解 vhost-scsi 存储虚拟化——高性能 VM 存储访问。

---

> [!tip] 参考文献
> - "vhost-user 协议", https://qemu.readthedocs.io/en/latest/interop/vhost-user.html
> - "virtio 规范", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html
> - Intel, "DPDK Vhost", https://doc.dpdk.org/guides/prog_guide/vhost_lib.html
