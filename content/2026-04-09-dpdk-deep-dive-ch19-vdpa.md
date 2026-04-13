---
title: "DPDK 深度探索 (十九)：VDPA 数据面加速与驱动"
date: 2026-04-09
tags: [dpdk, series, vdpa, virtio, datapath, hardware-offload, driver, vhost]
description: "深入理解 VDPA 机制——virtio 数据面的硬件卸载、vDPA 驱动、virtio-blk/virtio-net 加速、mlx5-vdpa、DPDK vdpa 库"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-18. 前十八章已完成
> 19. **第十九章：VDPA 数据面加速与驱动**

---

## 1. 概述：什么是 VDPA？

### 1.1 从软件到硬件的演进

VDPA (vhost Data Path Acceleration) 是将 vhost 数据路径卸载到硬件的关键技术：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    vhost 数据路径演进                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  阶段 1: 纯软件 vhost (vhost-net/vhost-scsi)                              │
│  ────────────────────────────────────────────                              │
│                                                                             │
│       ┌─────────┐                                                           │
│       │  VM     │                                                           │
│       └────┬────┘                                                           │
│            │ virtqueue                                                     │
│            ▼                                                                │
│       ┌─────────┐        ┌─────────────┐                                    │
│       │  QEMU   │───────►│  vhost-net  │                                    │
│       └────┬────┘        │  (kernel)   │                                    │
│            │             └──────┬──────┘                                    │
│            │                    │                                           │
│            │                 软件处理                                       │
│            │                    │                                           │
│            ▼                    ▼                                           │
│       ┌─────────────────────────────────────┐                              │
│       │          Physical NIC               │                              │
│       └─────────────────────────────────────┘                              │
│                                                                             │
│  问题: CPU 参与所有数据路径，瓶颈明显                                         │
│                                                                             │
│  阶段 2: vhost-user (用户态软件)                                           │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│       ┌─────────┐                                                           │
│       │  VM     │                                                           │
│       └────┬────┘                                                           │
│            │ virtqueue                                                     │
│            ▼                                                                │
│       ┌─────────┐        ┌─────────────┐                                    │
│       │  QEMU   │───────►│  vhost-user │                                    │
│       └─────────┘        │  (DPDK)     │                                    │
│                          └──────┬──────┘                                    │
│                                 │                                           │
│                                 │ 用户态转发                                 │
│                                 │                                           │
│                                 ▼                                           │
│                          ┌─────────────┐                                    │
│                          │  Physical   │                                    │
│                          │  NIC (DPDK) │                                    │
│                          └─────────────┘                                    │
│                                                                             │
│  改进: 绕过内核，减少一次拷贝                                                 │
│  问题: CPU 仍需处理 virtqueue 管理和数据移动                                │
│                                                                             │
│  阶段 3: VDPA (硬件加速)                                                   │
│  ────────────────────────────────                                          │
│                                                                             │
│       ┌─────────┐                                                           │
│       │  VM     │                                                           │
│       └────┬────┘                                                           │
│            │ virtqueue                                                     │
│            ▼                                                                │
│       ┌─────────┐                                                           │
│       │  QEMU   │───────► 控制平面 (VFIO)                                  │
│       └─────────┘                                                           │
│                          │                                                   │
│                          ▼                                                   │
│       ┌─────────────────────────────────────┐                              │
│       │         DPU / SmartNIC              │                              │
│       │  ┌─────────────────────────────────┐ │                              │
│       │  │       VDPA Driver               │ │                              │
│       │  │  (virtqueue 硬件管理)           │ │                              │
│       │  └──────────────┬──────────────────┘ │                              │
│       │                 │                     │                              │
│       │                 ▼                     │                              │
│       │  ┌─────────────────────────────────┐ │                              │
│       │  │     Hardware DMA Engine         │ │                              │
│       │  │     (virtqueue → NIC 直接)      │ │                              │
│       │  └──────────────┬──────────────────┘ │                              │
│       └────────────────┼────────────────────┘                              │
│                        │                                                    │
│                        ▼                                                    │
│                 ┌─────────────┐                                             │
│                 │  Physical   │                                             │
│                 │  NIC (HW)   │                                             │
│                 └─────────────┘                                             │
│                                                                             │
│  优势: CPU 完全不参与数据路径，virtqueue 由硬件管理                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 VDPA vs vhost-user vs KNI

| 特性 | KNI | vhost-user | VDPA |
|------|-----|------------|------|
| **数据路径** | 内核网络栈 | 用户态 DPDK | 硬件 DMA |
| **CPU 参与** | 每次操作 | 数据拷贝 | 完全不参与 |
| **延迟** | 高 (~50μs) | 中 (~5-10μs) | 低 (~1-2μs) |
| **吞吐量** | 受限 | 高 | 线速 |
| **功能** | 完整内核栈 | 灵活 | 受硬件限制 |
| **部署** | 简单 | 中等 | 需要特定硬件 |

### 1.3 VDPA 支持的设备类型

| 设备类型 | 说明 | 硬件厂商 |
|----------|------|----------|
| **virtio-net** | 网络 I/O 加速 | Mellanox, Intel, NVIDIA |
| **virtio-blk** | 块设备加速 | Mellanox, Intel |
| **virtio-scsi** | SCSI 加速 | 较少 |

---

## 2. VDPA 架构

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          VDPA 架构                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                            Host                                      │  │
│  │                                                                      │  │
│  │   ┌─────────┐         ┌─────────┐         ┌─────────┐               │  │
│  │   │   VM   │         │  QEMU   │         │  VFIO   │               │  │
│  │   │        │         │         │         │         │               │  │
│  │   │ virtio │◄───────►│ vhost-  │◄───────►│  PASSTHROUGH│             │  │
│  │   │ net/blk│         │ vdpa    │         │         │               │  │
│  │   └────┬────┘         └────┬────┘         └────┬────┘               │  │
│  │        │                   │                   │                    │  │
│  │        │ virtqueue         │ 控制              │ BAR 访问            │  │
│  │        └───────────────────┼───────────────────┘                    │  │
│  │                            │                                          │  │
│  └────────────────────────────┼──────────────────────────────────────────┘  │
│                               PCIe                                           │
│                                │                                             │
│  ┌────────────────────────────┼──────────────────────────────────────────┐  │
│  │                            ▼                                          │  │
│  │   ┌─────────────────────────────────────────────────────────────────┐ │  │
│  │   │                      DPU / SmartNIC                             │ │  │
│  │   │                                                                  │ │  │
│  │   │   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐           │ │  │
│  │   │   │   VDPA     │    │  Virtqueue │    │    DMA     │           │ │  │
│  │   │   │   Driver   │◄──►│  Manager   │◄──►│   Engine   │           │ │  │
│  │   │   │  (内核)    │    │  (硬件)    │    │  (硬件)    │           │ │  │
│  │   │   └─────┬──────┘    └──────┬──────┘    └──────┬──────┘           │ │  │
│  │   │         │                  │                  │                  │ │  │
│  │   │         │                  │                  ▼                  │ │  │
│  │   │         │                  │         ┌─────────────┐            │ │  │
│  │   │         │                  │         │   NIC      │            │ │  │
│  │   │         │                  │         │   (HW)     │            │ │  │
│  │   │         │                  │         └─────────────┘            │ │  │
│  │   └─────────┼──────────────────┼─────────────────────────────────────┘ │  │
│  │             │                  │                                       │  │
│  └─────────────┼──────────────────┼───────────────────────────────────────┘  │
│                │                  │                                            │
│                ▼                  ▼                                            │
│          控制平面           数据平面 (硬件 DMA)                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 控制平面 vs 数据平面

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    VDPA 控制平面 vs 数据平面                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  控制平面 (Host QEMU/VFIO → DPU)                                           │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│  1.  virtqueue 配置 (队列大小、地址)                                        │
│  2.  共享内存映射 (VM 内存区域的 GPA → HPA)                                │
│  3.  特性协商 (virtio 特性位)                                              │
│  4.  设备状态 (Device Status)                                               │
│  5.  MSI-X 中断配置                                                        │
│                                                                             │
│  数据平面 (DPU 硬件自主处理)                                                │
│  ────────────────────────────────                                          │
│                                                                             │
│  1.  DMA 读取 VM 内存 (virtqueue desc)                                     │
│  2.  数据处理 (校验和、分割、加密等)                                         │
│  3.  DMA 写入 VM 内存 (used ring 更新)                                     │
│  4.  中断通知 VM (MSI-X)                                                   │
│                                                                             │
│  关键: 控制平面经过 CPU，数据平面完全硬件处理                                 │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. VDPA 驱动

### 3.1 内核 VDPA 驱动架构

```c
// kernel/drivers/vdpa/ 目录结构

/*
 * vdpa 核心抽象层
 * ─────────────────
 * 提供统一的 vdpa_device 接口
 * 屏蔽底层硬件差异
 */

// 核心结构
struct vdpa_device {
    struct device dev;              // Linux 设备模型
    struct vdpa_device_ops *ops;    // 硬件特定操作

    // 设备信息
    char *name;
    int max_virtqueue_pairs;
    int max_sz_g;
    int use_event_idx;
    int suspend_vq;
};

// vdpa 设备操作接口
struct vdpa_device_ops {
    // 获取设备配置
    void *(*get_config)(struct vdpa_device *vdev, size_t *len);

    // 设置 virtqueue 回调
    void (*set_vq_cb)(struct vdpa_device *vdev, u16 idx,
                      struct vdpa_callback *cb);

    // 设置 virtqueue 地址
    int (*set_vq_address)(struct vdpa_device *vdev, u16 idx,
                          u64 desc_area, u64 avail_area, u64 used_area);

    // 启用/禁用 virtqueue
    void (*set_vq_state)(struct vdpa_device *vdev, u16 idx,
                         const struct vdpa_vq_state *state);
    int (*get_vq_state)(struct vdpa_device *vdev, u16 idx,
                        struct vdpa_vq_state *state);

    // virtqueue 管理
    int (*resume_vq)(struct vdpa_device *vdev, u16 idx);
    int (*suspend_vq)(struct vdpa_device *vdev, u16 idx);

    // 获取 virtqueue 数量
    u16 (*get_vq_num_max)(struct vdpa_device *vdev);
    u32 (*get_vq_num_min)(struct vdpa_device *vdev);

    // 设备管理
    int (*set_features)(struct vdpa_device *vdev, u64 features);
    u64 (*get_features)(struct vdpa_device *vdev);
    int (*set_status)(struct vdpa_device *vdev, u8 status);
    u8 (*get_status)(struct vdpa_device *vdev);

    // DMA 映射
    int (*set_map)(struct vdpa_device *vdev, unsigned int asid,
                   struct vhost_iotlb *iotlb);
    int (*dma_map)(struct vdpa_device *vdev, unsigned int asid,
                   u64 iova, u64 size, u64 pa, u32 perm, void *opaque);
    int (*dma_unmap)(struct vdpa_device *vdev, unsigned int asid,
                     u64 iova, u64 size);

    // 厂商特定操作
    int (*set_vq_vector)(struct vdpa_device *vdev, u16 idx, int vector);
    int (*set_vq_ready)(struct vdpa_device *vdev, u16 idx, bool ready);
};
```

### 3.2 mlx5 VDPA 驱动

```c
// drivers/net/ethernet/mellanox/mlx5_vdpa/

// mlx5 VDPA 设备结构
struct mlx5_vdpa_dev {
    struct vdpa_device vdev;         // 继承 vdpa_device

    struct pci_dev *pdev;           // PCIe 设备
    struct mlx5_core_dev *mdev;     // mlx5 核心设备

    // virtqueue
    struct mlx5_vdpa_virtqueue *vqs;
    int max_vqs;

    // 共享内存
    struct mlx5_vdpa_mr mr;         // Memory Region

    // 工作队列
    struct mlx5_vdpa_virtqueue **vqs;
    struct workqueue_struct *cb_wq;
};

// 设置 virtqueue 地址
static int
mlx5_vdpa_set_vq_address(struct vdpa_device *vdev,
                          u16 idx,
                          u64 desc_area, u64 avail_area, u64 used_area)
{
    struct mlx5_vdpa_dev *dev = to_mlx5_vdpa_dev(vdev);
    struct mlx5_vdpa_virtqueue *mvq = &dev->vqs[idx];

    // 转换 GPA 到 HPA
    mvq->desc_addr = mlx5_vdpa_gpa_to_hpa(dev, desc_area);
    mvq->avail_addr = mlx5_vdpa_gpa_to_hpa(dev, avail_area);
    mvq->used_addr = mlx5_vdpa_gpa_to_hpa(dev, used_area);

    // 配置硬件 virtqueue
    mlx5_vdpa_setup_virtqueue(dev, mvq);

    return 0;
}

// 获取设备特性
static u64
mlx5_vdpa_get_features(struct vdpa_device *vdev)
{
    u64 features = 0;

    // virtio-net 特性
    features |= (1ULL << VIRTIO_NET_F_CSUM);
    features |= (1ULL << VIRTIO_NET_F_GUEST_CSUM);
    features |= (1ULL << VIRTIO_NET_F_MAC);
    features |= (1ULL << VIRTIO_NET_F_GUEST_TSO4);
    features |= (1ULL << VIRTIO_NET_F_GUEST_TSO6);
    features |= (1ULL << VIRTIO_F_RING_INDIRECT_DESC);
    features |= (1ULL << VIRTIO_F_RING_EVENT_IDX);
    features |= (1ULL << VIRTIO_NET_F_MRG_RXBUF);
    features |= (1ULL << VIRTIO_F_VERSION_1);

    // VDPA 特定特性
    features |= (1ULL << VHOST_F_LOG_ALL);
    features |= (1ULL << VIRTIO_F_ACCESS_PLATFORM);

    return features;
}

// DMA 映射
static int
mlx5_vdpa_dma_map(struct vdpa_device *vdev, unsigned int asid,
                  u64 iova, u64 size, u64 pa, u32 perm, void *opaque)
{
    struct mlx5_vdpa_dev *dev = to_mlx5_vdpa_dev(vdev);

    // 在硬件中配置 IOVA → PA 映射
    return mlx5_core_mrereg(dev->mdev, asid, iova, size, pa, perm);
}
```

### 3.3 VDPA net 驱动 (virtio-net 加速)

```c
// mlx5 VDPA net 驱动

struct mlx5_vdpa_net {
    struct mlx5_vdpa_dev mvdev;

    // net 特定配置
    uint8_t mac[ETH_ALEN];
    uint16_t mtu;
    uint16_t status;

    // 特性
    bool csum_offload;
    bool tso_en;
    bool mrg_rx;
};

// virtio-net 配置
static void *
mlx5_vdpa_net_get_config(struct vdpa_device *vdev, size_t *len)
{
    struct mlx5_vdpa_net *net = to_mlx5_vdpa_net(vdev);
    static struct virtio_net_config config;

    memset(&config, 0, sizeof(config));
    memcpy(config.mac, net->mac, ETH_ALEN);
    config.mtu = rte_cpu_to_le_16(net->mtu);
    config.status = rte_cpu_to_le_16(net->status);
    config.max_virtqueue_pairs = rte_cpu_to_le_16(net->mvdev.max_vqs / 2);

    *len = sizeof(config);
    return &config;
}

// 数据路径 (硬件处理，驱动不参与)
static void
mlx5_vdpa_vq_done(struct mlx5_vdpa_virtqueue *mvq)
{
    // 硬件完成中断
    // 通知应用程序（如果有回调）
    if (mvq->cb.callback) {
        mvq->cb.callback(mvq->cb.private);
    }
}
```

---

## 4. QEMU VDPA 支持

### 4.1 QEMU 命令行配置

```bash
# 启动 VM 使用 VDPA (需要 Mellanox ConnectX)
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    # 启用 vhost-user-vdpa 后端
    -device vhost-user-vdpa-pci,id=vhostvdpa0,chardev=vhostvdpa0 \
    # 配置 vhost-user 字符设备
    -chardev socket,id=vhostvdpa0,path=/tmp/vhost-vdpa0.sock \
    # 或者使用 virtio-net-vdpa (直接 virtio-net)
    -netdev virtio-net-vdpa,id=vdpanet0,driver=/dev/vhost-vdpa-0 \
    -device virtio-net-pci,netdev=vdpanet0,mac=00:11:22:33:44:55
```

### 4.2 vhost-user-vdpa 架构

```c
// QEMU 中的 vhost-user-vdpa 实现

struct vhost_user_vdpa {
    CharBackend *chardev;          // 字符设备 (Unix socket)
    struct vhost_dev dev;          // vhost 设备
    struct vhost_vdpa *vdpa_dev;   // VDPA 设备

    int device_fd;                 // /dev/vhost-vdpa 句柄
    int nvqs;                      // virtqueue 数量
};

// 打开 VDPA 设备
static int
vhost_user_vdpa_get_device_fd(struct vhost_user_vdpa *vuv)
{
    // 打开 /dev/vhost-vdpa 字符设备
    vuv->device_fd = open("/dev/vhost-vdpa", O_RDWR);
    if (vuv->device_fd < 0) {
        error_report("Cannot open /dev/vhost-vdpa");
        return -1;
    }

    // 设置 VDPA 设备路径
    struct vhost_vdpa vdpa_dev = {
        .path = "/sys/class/vhost-vdpa/vhost-vdpa-0",
    };

    ioctl(vuv->device_fd, VHOST_SET_VDPA_DEVICE_NAME, &vdpa_dev);

    return 0;
}
```

---

## 5. DPDK vdpa 库

### 5.1 DPDK VDPA 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DPDK VDPA 库架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                         DPDK vdpa 库                                 │  │
│  │  (lib/librte_vdpa/)                                                │  │
│  │                                                                      │  │
│  │  ┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐  │  │
│  │  │  rte_vdpa_map   │    │  rte_vdpa_device │    │  rte_vdpa_queue │  │  │
│  │  │  (DMA 映射)     │    │  (设备管理)      │    │  (virtqueue)    │  │  │
│  │  └────────┬────────┘    └────────┬────────┘    └────────┬────────┘  │  │
│  │           │                       │                       │          │  │
│  │           └───────────────────────┼───────────────────────┘          │  │
│  │                                   │                                      │  │
│  │                                   ▼                                      │  │
│  │  ┌───────────────────────────────────────────────────────────────┐   │  │
│  │  │              VDPA Driver (mlx5_vdpa, etc)                     │   │  │
│  │  │                                                               │   │  │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐       │   │  │
│  │  │  │  DMA    │  │  Virtq  │  │  MR     │  │  CQ     │       │   │  │
│  │  │  │  Engine │  │  Manager│  │  (内存) │  │  完成   │       │   │  │
│  │  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘       │   │  │
│  │  └───────────────────────────────────────────────────────────────┘   │  │
│  │                                                                      │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 DPDK vdpa API

```c
// lib/librte_vdpa/rte_vdpa.h

// VDPA 设备结构
struct rte_vdpa_device {
    int device_fd;                 // /dev/vhost-vdpa 句柄
    int vid;                       // virtio device ID

    // 设备能力
    uint64_t features;            // 支持的特性
    uint32_t max_queues;          // 最大队列数
    bool virtio_net_hdr;         // 是否支持 virtio-net 头

    // 底层驱动
    struct rte_vdpa_ops *ops;
    void *priv;                   // 驱动私有数据
};

// VDPA 操作接口
struct rte_vdpa_ops {
    // 获取设备配置
    int (*get_config)(struct rte_vdpa_device *dev,
                      struct rte_vdpa_device_config *config);

    // 设置设备特性
    int (*set_features)(struct rte_vdpa_device *dev, uint64_t features);

    // 设置 virtqueue 地址
    int (*set_vq_addr)(struct rte_vdpa_device *dev,
                       uint16_t qid, uint64_t desc, uint64_t avail,
                       uint64_t used);

    // 获取/设置 virtqueue 状态
    int (*get_vq_state)(struct rte_vdpa_device *dev,
                        uint16_t qid, struct rte_vdpa_vq_state *state);
    int (*set_vq_state)(struct rte_vdpa_device *dev,
                        uint16_t qid, struct rte_vdpa_vq_state *state);

    // virtqueue 管理
    int (*setup_vq)(struct rte_vdpa_device *dev, uint16_t qid);
    int (*start_vq)(struct rte_vdpa_device *dev, uint16_t qid);
    int (*stop_vq)(struct rte_vdpa_device *dev, uint16_t qid);
    int (*reset_vq)(struct rte_vdpa_device *dev, uint16_t qid);

    // DMA 映射
    int (*dma_map)(struct rte_vdpa_device *dev,
                   uint64_t iova, uint64_t size, uint64_t addr, int perm);
    int (*dma_unmap)(struct rte_vdpa_device *dev,
                     uint64_t iova, uint64_t size);

    // 中断处理
    int (*set_vq_intr)(struct rte_vdpa_device *dev,
                       uint16_t qid, int fd, int vector);
};
```

### 5.3 使用 DPDK vdpa 库

```c
// DPDK VDPA 使用示例

#include <rte_eal.h>
#include <rte_vdpa.h>
#include <rte_vhost.h>

// VDPA 设备配置
struct vdpa_context {
    struct rte_vdpa_device *vdpa_dev;
    int vid;                       // vhost device ID
    uint16_t vq_num;              // virtqueue 数量
};

// 初始化 VDPA
static struct vdpa_context *
vdpa_init(const char *device_path, int vid)
{
    struct vdpa_context *ctx;
    struct rte_vdpa_device *dev;

    // 查找 VDPA 设备
    dev = rte_vdpa_find_device_by_name(device_path);
    if (!dev) {
        printf("VDPA device not found: %s\n", device_path);
        return NULL;
    }

    ctx = calloc(1, sizeof(*ctx));
    ctx->vdpa_dev = dev;
    ctx->vid = vid;

    // 获取设备能力
    uint64_t features = rte_vdpa_get_features(dev);
    printf("VDPA device features: 0x%lx\n", features);

    ctx->vq_num = rte_vdpa_get_num_queues(dev);
    printf("VDPA max queues: %u\n", ctx->vq_num);

    // DMA 映射 VM 内存
    // (通常由 QEMU/VFIO 自动完成)

    return ctx;
}

// 设置 virtqueue
static int
vdpa_setup_queue(struct vdpa_context *ctx, uint16_t qid)
{
    struct rte_vdpa_device *dev = ctx->vdpa_dev;
    uint64_t desc, avail, used;
    struct vhost_vring_addr addr = {0};

    // 获取 vhost virtqueue 地址
    if (rte_vhost_get_vring_base(ctx->vid, qid, &desc, &avail, &used) < 0) {
        return -1;
    }

    // 配置 VDPA virtqueue
    if (dev->ops->set_vq_addr(dev, qid, desc, avail, used) < 0) {
        return -1;
    }

    // 启用 virtqueue
    if (dev->ops->start_vq(dev, qid) < 0) {
        return -1;
    }

    printf("VDPA queue %u configured\n", qid);
    return 0;
}

// 轮询 VDPA 完成队列
static void
vdpa_poll_completions(struct vdpa_context *ctx)
{
    struct rte_vdpa_device *dev = ctx->vdpa_dev;

    // 轮询每个 virtqueue 的完成队列
    for (uint16_t qid = 0; qid < ctx->vq_num; qid++) {
        // 检查完成队列
        uint16_t completed = dev->ops->poll_completion(dev, qid);

        if (completed > 0) {
            printf("Queue %u: %u completions\n", qid, completed);
        }
    }
}

// 主循环
int
vdpa_main_loop(struct vdpa_context *ctx)
{
    printf("VDPA main loop started\n");

    while (!quit) {
        // 轮询完成
        vdpa_poll_completions(ctx);

        // (数据路径完全由硬件处理，无需软件参与)
    }

    return 0;
}
```

---

## 6. 硬件 virtqueue 管理

### 6.1 硬件 virtqueue 结构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    硬件 virtqueue vs 软件 virtqueue                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  软件 virtqueue (vhost-user)                                               │
│  ───────────────────────────                                                │
│                                                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                                  │
│  │  desc    │  │  avail    │  │  used     │                                  │
│  │  table   │  │  ring     │  │  ring     │                                  │
│  │ (RAM)    │  │  (RAM)    │  │  (RAM)    │                                  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                                  │
│       │              │              │                                       │
│       └──────────────┼──────────────┘                                       │
│                      │                                                      │
│                      ▼                                                      │
│               CPU 处理 (软件)                                               │
│                                                                             │
│  硬件 virtqueue (VDPA)                                                     │
│  ─────────────────────────                                                  │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                      DPU / SmartNIC 硬件                              │  │
│  │                                                                      │  │
│  │   ┌────────────┐    ┌────────────┐    ┌────────────┐                │  │
│  │   │  Hardware  │    │  Hardware  │    │  Hardware  │                │  │
│  │   │  desc      │    │  avail     │    │  used      │                │  │
│  │   │  Walker    │    │  Producer  │    │  Consumer  │                │  │
│  │   └─────┬──────┘    └─────┬──────┘    └─────┬──────┘                │  │
│  │         │                 │                  │                        │  │
│  │         │                 │                  │                        │  │
│  │         ▼                 │                  │                        │  │
│  │   ┌───────────┐           │                  │                        │  │
│  │   │   DMA    │           │                  │                        │  │
│  │   │   Engine │◄──────────┴──────────────────┘                        │  │
│  │   │          │                                                      │  │
│  │   └─────┬────┘                                                      │  │
│  │         │                                                            │  │
│  │         ▼                                                            │  │
│  │   ┌───────────┐                                                      │  │
│  │   │   NIC    │                                                      │  │
│  │   │   TX/RX  │                                                      │  │
│  │   └───────────┘                                                      │  │
│  │                                                                      │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                      ▲                   ▲                                 │
│                      │                   │                                 │
│            VM 内存 (GPA)       VM 内存 (GPA)                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 硬件 DMA 引擎

```c
// 硬件 DMA 引擎工作流程

// 1. 硬件 virtqueue walker 检测到新的 avail desc
// 2. DMA 引擎读取 desc (从 VM 内存)
// 3. 根据 desc.addr DMA 读取数据
// 4. 数据发送到 NIC 或进行处理
// 5. 更新 used ring (DMA 写入)
// 6. 触发 MSI-X 中断通知 VM

// 硬件描述符
struct hw_virtq_desc {
    uint64_t addr;         // 缓冲区地址
    uint32_t len;          // 长度
    uint16_t flags;        // 标志
    uint16_t next;         // 链式下一个
};

// DMA 传输请求
struct dma_request {
    uint64_t src_addr;     // 源地址 (VM GPA)
    uint64_t dst_addr;     // 目标地址 (NIC/内存)
    uint32_t len;
    uint16_t vq_id;        // virtqueue ID
    uint16_t desc_idx;     // 描述符索引
};
```

---

## 7. 性能对比

### 7.1 VDPA vs 其他方案

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    数据面方案性能对比 (64B 包)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  吞吐量 (Mpps)                                                             │
│  │                                                                        │
│  200 ┤                                                                ████  │
│      │                                                            ████      │
│  150 ┤                                                        ████          │
│      │                                                    ████              │
│  100 ┤                                            ████████                    │
│      │                                    ████████                          │
│   50 ┤                        █████████████                                   │
│      │            ████████████                                              │
│    0 ┤███████████████████                                                    │
│      └────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──  │
│           KNI  vhost-  VDPA virtio-  VDPA  物理  物理                       │
│                 user   (mlx5)  net SW  (mlx5)  NIC                          │
│                                   +TSO                                       │
│                                                                             │
│  CPU 利用率 (%)                                                             │
│  │                                                                        │
│  100 ┤████                                                              ██  │
│      │████                                                          ██  ██  │
│   75 ┤████                                                          ██  ██  │
│      │████                                                      ██  ██      │
│   50 ┤████                                                  ██  ██          │
│      │████                                              ██  ██              │
│   25 ┤████                                          ██  ██                  │
│      │████              ██  ██  ██  ██  ██  ██                          │
│    0 ┤████▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                      │
│      └────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──  │
│           KNI  vhost-  VDPA virtio-  VDPA  物理  物理                       │
│                 user   (mlx5)  net SW  (mlx5)  NIC                          │
│                                                                             │
│  图例: ██ = CPU 利用率   ▒▒ = 低/零 CPU                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 VDPA 加速比

| 场景 | 方案 | 吞吐量 | CPU 利用率 | 加速比 |
|------|------|--------|------------|--------|
| **64B 小包** | vhost-user | 5 Mpps | 100% | 1x |
| **64B 小包** | VDPA (mlx5) | 50 Mpps | 5% | 10x |
| ** Jumbo 帧** | vhost-user | 15 Gbps | 80% | 1x |
| ** Jumbo 帧** | VDPA (mlx5) | 100 Gbps | 10% | 6.7x |
| **存储 IOPS** | vhost-blk | 200K IOPS | 90% | 1x |
| **存储 IOPS** | VDPA (mlx5) | 1.2M IOPS | 15% | 6x |

---

## 8. VDPA 部署

### 8.1 硬件要求

| 组件 | 要求 |
|------|------|
| **DPU/SmartNIC** | Mellanox ConnectX-6/7, NVIDIA BlueField-2/3 |
| **驱动** | mlx5_core, mlx5_vdpa (Linux kernel 5.10+) |
| **固件** | 最新 VDPA 固件 |
| **QEMU** | 6.0+ |
| **DPDK** | 21.02+ |

### 8.2 部署步骤

```bash
# 1. 检查 VDPA 设备
ls -la /sys/class/vhost-vdpa/

# 2. 加载 VDPA 驱动
modprobe mlx5_vdpa

# 3. 配置 DPU 端口
# (参考 DPU 文档)

# 4. 启动 QEMU with VDPA
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -enable-kvm \
    -device vhost-user-vdpa-pci,id=vvdpa0,chardev=vvdpa0 \
    -chardev socket,id=vvdpa0,path=/var/run/vhost-vdpa0.sock \
    -object memory-backend-file,id=mem0,size=4G,share=on \
    -machine q35,memory-backend=mem0

# 5. 在 Guest 内使用标准 virtio-net 驱动
# (无需特殊驱动)
```

---

## 9. 小结

本章核心要点：

1. **VDPA 背景**：将 vhost 数据路径卸载到硬件，CPU 完全不参与数据平面，实现近乎线速的 virtio I/O。

2. **演进路径**：纯软件 vhost → vhost-user (用户态) → VDPA (硬件卸载)。

3. **架构**：控制平面通过 VFIO/P CIe 配置 DPU，数据平面由 DPU 硬件 (DMA Engine + Virtqueue Manager) 自主处理。

4. **内核 VDPA 驱动**：vdpa_device 抽象层 + 厂商特定驱动 (mlx5_vdpa)，提供统一的 virtqueue 和 DMA 映射接口。

5. **QEMU 支持**：vhost-user-vdpa 设备类型，通过 Unix socket 与 VDPA 驱动交互。

6. **DPDK vdpa 库**：rte_vdpa_device + rte_vdpa_ops，封装厂商驱动，提供配置和轮询接口。

7. **硬件 virtqueue**：DPU 内部实现 desc/avail/used walker 和 DMA 引擎，直接从 VM 内存 DMA 访问数据。

8. **性能优势**：小包 10x 加速，CPU 利用率降低 95%，支持 100Gbps+ 线速。

9. **硬件要求**：Mellanox/NVIDIA DPU，Linux 5.10+，QEMU 6.0+。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch20-simd-avx512|第二十章]]将讲解 AVX512/SIMD 数据包处理向量化——DPDK 高性能的秘密武器。

---

> [!tip] 参考文献
> - "VDPA 规范", https://www.kernel.org/doc/html/latest/userspace-api/vdpa.html
> - Intel, "DPDK Vhost", https://doc.dpdk.org/guides/prog_guide/vhost_lib.html
> - Mellanox, "mlx5 VDPA driver", https://docs.nvidia.com/networking/category/mlx5drivers
> - "vDPA 概述", https://www.redhat.com/en/blog/introduction-vdpa
