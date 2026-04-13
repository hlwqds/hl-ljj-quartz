---
title: "VPP 深入探讨 ch16：VPP + KVM/vhost-user"
date: 2026-04-10 02:00:00
tags: [vpp, kvm, qemu, vhost-user, virtio, vm, virtualization, shared-memory]
description: "深入解析 VPP 与 KVM 集成：vhost-user 协议、Virtio 网卡、共享内存、VM 网络加速"
---

# VPP 深入探讨 ch16：VPP + KVM/vhost-user

> [!abstract] 核心要点
> VPP 可作为 VM 的网络加速器。本章深入解析 vhost-user 协议、Virtio 网卡、共享内存映射与 VM 网络加速配置。

## 1. vhost-user 概述

### 1.1 为什么需要 vhost-user

```
传统 virtio vs vhost-user：

传统 virtio (vhost-net kernel 模块)：
  Guest VM → virtio-net → vhost-net (kernel) → NIC
                                        ↑
                                    VM exit

vhost-user (VPP 在用户态)：
  Guest VM → virtio-net → vhost-user (VPP) → NIC
                                        ↑
                                    无 VM exit

优势：
  - 减少 VM exit（中断/配置）
  - 用户态处理，低延迟
  - 可使用 DPDK 驱动
  - 更灵活的协议扩展
```

### 1.2 vhost-user vs vhost-net

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 架构                         │
│                                                              │
│  ┌─────────────┐                                            │
│  │   VPP       │ ← 用户态进程                             │
│  │  (vhost-user)│                                            │
│  └──────┬──────┘                                            │
│         │                                                    │
│         │  Unix Socket                                      │
│         │                                                    │
│  ┌──────┴──────┐                                            │
│  │  QEMU/KVM   │                                            │
│  └──────┬──────┘                                            │
│         │                                                    │
│  ┌──────┴──────┐                                            │
│  │   Guest     │                                            │
│  │  virtio-net │                                            │
│  └─────────────┘                                            │
└─────────────────────────────────────────────────────────────┘
```

## 2. vhost-user 协议

### 2.1 协议消息

```
vhost-user 使用 Unix Domain Socket 通信：

┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 消息                         │
│                                                              │
│  特性协商：                                                  │
│  - VHOST_USER_GET_FEATURES                                │
│  - VHOST_USER_SET_FEATURES                                │
│  - VHOST_USER_SET_PROTOCOL_FEATURES                        │
│                                                              │
│  内存映射：                                                  │
│  - VHOST_USER_SET_MEM_TABLE                               │
│  - VHOST_USER_SET_LOG_BASE                                │
│                                                              │
│  Virtio 队列：                                               │
│  - VHOST_USER_SET_VRING_KICK                              │
│  - VHOST_USER_SET_VRING_CALL                              │
│  - VHOST_USER_SET_VRING_ERR                               │
│                                                              │
│  链路状态：                                                  │
│  - VHOST_USER_GET_LINKER                                   │
│  - VHOST_USER_SET_LINKER                                   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 消息格式

```c
// vhost-user 消息头
typedef struct {
    u32 request;        // 消息类型
    u32 flags;          // 标志
    u64 size;           // 消息负载大小
} vhost_user_msg_t;

// 请求类型
enum vhost_user_request {
    VHOST_USER_NONE = 0,
    VHOST_USER_GET_FEATURES = 1,
    VHOST_USER_SET_FEATURES = 2,
    VHOST_USER_SET_MEM_TABLE = 3,
    VHOST_USER_SET_VRING_KICK = 4,
    VHOST_USER_SET_VRING_CALL = 5,
    VHOST_USER_SET_VRING_ERR = 6,
    // ...
};
```

### 2.3 特性协商

```c
// Virtio/vhost-user 特性
enum vhost_user_feature {
    VHOST_USER_F_LOG_ALL = 26,
    VHOST_USER_F_PROTOCOL_FEATURES = 30,
    VHOST_USER_F_MAC_TABLE = 31,
    VHOST_USER_F_STATE = 34,
};

// Virtio 特性
enum virtio_feature {
    VIRTIO_NET_F_CSUM = 0,       // checksum offload
    VIRTIO_NET_F_GUEST_CSUM = 1,
    VIRTIO_NET_F_MAC = 5,
    VIRTIO_NET_F_HOST_TSO4 = 6,
    VIRTIO_NET_F_GUEST_TSO4 = 7,
    VIRTIO_NET_F_MRG_RXBUF = 15, // multi-buffer
    VIRTIO_F_VERSION_1 = 32,      // virtio 1.0
    VIRTIO_F_IOMMU_PLATFORM = 33,
    VIRTIO_NET_F_MTU = 39,
    // ...
};
```

## 3. Virtio 网卡

### 3.1 Virtio 队列

```
Virtio 使用环形队列：

┌─────────────────────────────────────────────────────────────┐
│                    Virtio 环形队列                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Descriptor Table                   │   │
│  │  ┌────────┬────────┬────────┬────────┐              │   │
│  │  │ Desc 0 │ Desc 1 │ Desc 2 │ Desc 3 │ ...        │   │
│  │  └────────┴────────┴────────┴────────┘              │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌───────────────┐  ┌───────────────┐                      │
│  │ Available Ring │  │ Used Ring      │                      │
│  │ (host ← guest)│  │ (host → guest) │                      │
│  └───────────────┘  └───────────────┘                      │
│                                                              │
│  Descriptor:                                                │
│  - addr: 物理地址                                           │
│  - len: 长度                                               │
│  - flags: NEXT, WRITE                                       │
│  - next: 下一个 descriptor                                  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 vhost-user Virtio 实现

```c
// Virtio 设备状态
typedef struct {
    // 设备配置
    u64 features;           // negotiated features
    u64 protocol_features;

    // MAC 地址
    u8 mac[6];

    // Virtio 队列
    struct vring {
        u64 guest_phys_addr;    // GPA
        u64 gpa_size;            // 大小
        u64 userspace_addr;      // UVA
        u16 queue_size;          // 描述符数

        // 指针
        void *desc;              // descriptor table
        void *avail;             // available ring
        void *used;              // used ring

        // 索引
        u16 last_used_idx;
        u16 last_avail_idx;
    } vrings[VIRTIO_MAX_QUEUE];

    // 状态
    int enabled;
    int started;
} vhost_user_device_t;
```

## 4. 共享内存映射

### 4.1 内存表

```
vhost-user 通过内存映射共享 VM 内存：

VHOST_USER_SET_MEM_TABLE 消息包含：

┌─────────────────────────────────────────────────────────────┐
│                    Memory Region                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  guest_phys_addr: 起始 GPA (VM 物理地址)            │   │
│  │  memory_size:     region 大小                        │   │
│  │  userspace_addr: 起始 UVA (VPP 虚拟地址)             │   │
│  │  mmap_offset:     文件偏移                           │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘

VPP 通过 GPA → UVA 映射直接访问 VM 内存
```

### 4.2 内存映射实现

```c
// 设置内存表
static int
vhost_user_set_mem_table(vhost_user_device_t *dev,
                         vhost_user_msg_t *msg)
{
    for (int i = 0; i < msg->nregions; i++) {
        vhost_memory_region_t *reg = &msg->regions[i];

        // 获取 VM 物理地址
        u64 gpa = reg->guest_phys_addr;
        u64 size = reg->memory_size;

        // 映射到用户态
        void *uva = mmap(NULL, size,
                        PROT_READ | PROT_WRITE,
                        MAP_SHARED,
                        dev->mem_fd,
                        reg->mmap_offset);

        if (uva == MAP_FAILED) {
            return -1;
        }

        // 保存映射信息
        dev->regions[i].gpa = gpa;
        dev->regions[i].uva = uva;
        dev->regions[i].size = size;

        // 创建 GPA → UVA 转换表
        gpa_to_uva_map[gpa] = uva;
    }

    return 0;
}

// GPA 到 UVA 转换
static inline void *
gpa_to_uva(u64 gpa)
{
    for (int i = 0; i < num_regions; i++) {
        if (gpa >= regions[i].gpa &&
            gpa < regions[i].gpa + regions[i].size) {
            return regions[i].uva + (gpa - regions[i].gpa);
        }
    }
    return NULL;
}
```

## 5. vhost-user 配置

### 5.1 QEMU 配置

```bash
# QEMU 启动参数
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -enable-kvm \
    -device virtio-net-pci,mac=52:54:00:12:34:56,netdev=net0 \
    -netdev vhost-user,id=net0,queues=4,\
chardev=char0 \
    -chardev socket,id=char0,path=/var/run/vpp/vhost.sock,\
server=on,wait=off

# 多队列配置
# queues=4 启用 4 个 virtqueue pair
```

### 5.2 VPP 配置

```bash
# 创建 vhost-user 接口
vpp# create vhost-user socket /var/run/vpp/vhost.sock

# 查看 vhost-user 接口
vpp# show vhost-user

# 示例输出：
# vhost-user0: socket=/var/run/vpp/vhost.sock
#   Features: csum offload, guest tso4, mrg rxbuf
#   Queues: 4
#   State: active
```

### 5.3 启用多队列

```bash
# 配置 vhost-user 多队列
vpp# set interface virtio-net vhost-user0 queues 4

# 将接口加入 Bridge Domain
vpp# create bridge-domain bd_id 10
vpp# set interface l2 bridge vhost-user0 bd_id 10

# 查看多队列状态
vpp# show hardware vhost-user0
```

## 6. 零拷贝优化

### 6.1 vhost-user 零拷贝

```
vhost-user 零拷贝流程：

传统：
  NIC DMA → Buffer → CPU Copy → VM Memory
                              ↑
                          无必要拷贝

零拷贝：
  NIC DMA → Buffer → VM Memory (直接映射)
                        ↑
                    零拷贝

实现：
  1. VPP 和 VM 共享 hugepage 内存
  2. VM 的 virtio descriptor 指向共享内存
  3. VPP 直接填充 descriptor 的 buffer
```

### 6.2 内存共享

```c
// 创建共享内存区域
static int
create_shared_memory(size_t size, int *fd, void **addr)
{
    // 创建 anonymous hugepage 文件
    *fd = hugetlbfs_create(size);
    if (*fd < 0) return -1;

    // 映射到用户态
    *addr = mmap(NULL, size,
                PROT_READ | PROT_WRITE,
                MAP_SHARED,
                *fd, 0);

    if (*addr == MAP_FAILED) {
        close(*fd);
        return -1;
    }

    return 0;
}

// VPP 填充 VM buffer
static inline int
vhost_user_tx_to_vm(vhost_user_device_t *dev,
                    u16 qid,
                    vlib_buffer_t *b)
{
    // 获取 VM 的 descriptor
    struct vring_desc *desc = &dev->vrings[qid].desc[qid];

    // 转换为 VM 虚拟地址
    void *vm_buf = gpa_to_uva(desc->addr);

    // 直接拷贝（或零拷贝 if 共享内存）
    memcpy(vm_buf, b->data, b->current_length);

    // 更新 used ring
    desc->len = b->current_length;

    return 0;
}
```

## 7. 性能调优

### 7.1 QEMU 参数

```bash
# 优化的 QEMU 参数
qemu-system-x86_64 \
    -object memory-backend-file,id=mem,size=4G,\
mem-path=/dev/hugepages,share=on \
    -numa node,memdev=mem \
    -device virtio-net-pci,\
netdev=net0,\
mrxqpackets=1024,\
mtu=9000 \
    -netdev vhost-user,id=net0,\
queues=4,\
vhostforce=on,\
chardev=char0
```

### 7.2 VPP 参数

```bash
# VPP 配置 vhost-user
vpp# set vhost-user mtu 9000
vpp# set vhost-user checksum offload vhost-user0
vpp# set vhost-user tso offload vhost-user0
```

## 8. 总结

vhost-user 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    vhost-user 数据路径                       │
│                                                              │
│  Guest VM                                                   │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ virtio-net driver                                    │  │
│  │   - Virtqueue (TX/RX)                               │  │
│  │   - Descriptor Table                                 │  │
│  │   - Available/Used Ring                              │  │
│  └──────────────────────────────────────────────────────┘  │
│           ↑ shared memory (hugepages)                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ VPP vhost-user                                      │  │
│  │   - 直接访问 VM descriptor                          │  │
│  │   - 无 VM exit                                      │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

关键优势：

| 特性 | 传统 virtio | vhost-user |
|------|-------------|------------|
| **VM Exit** | 频繁 | 极少 |
| **延迟** | 高 | 低 |
| **吞吐量** | 中 | 高 |
| **CPU 开销** | 高 | 低 |
| **灵活性** | 低 | 高 |

---

## 参考资源

- [vhost-user 协议](https://qemu.readthedocs.io/en/latest/interop/vhost-user.html)
- [Virtio 规范](https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html)
- [VPP vhost-user](https://wiki.fd.io/view/VPP/vhost_user)
