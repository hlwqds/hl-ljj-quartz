---
title: "DPDK 深度探索 (十九)：VDPA 数据面加速与驱动"
date: 2026-04-09
tags: [dpdk, series, vdpa, virtio, datapath, hardware-offload, driver, vhost]
description: "深入理解 VDPA 机制——virtio 数据面的硬件卸载、vDPA 驱动、virtio-blk/virtio-net 加速、mlx5-vdpa、DPDK vdpa 库"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-18. 前十八章已完成 19. **第十九章：VDPA 数据面加速与驱动**

---

## 1. 概述：什么是 VDPA？

### 1.1 从软件到硬件的演进

VDPA (vhost Data Path Acceleration) 是将 vhost 数据路径卸载到硬件的关键技术：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    vhost 数据路径演进                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  阶段 1: 纯软件 vhost (vhost-net) — 数据经过内核                           │
│  ────────────────────────────────────────────────────────                  │
│                                                                             │
│       ┌─────────┐                                                           │
│       │  VM     │                                                           │
│       └────┬────┘                                                           │
│            │ virtqueue                                                     │
│            ▼                                                                │
│       ┌─────────┐        ┌─────────────┐        ┌─────────────┐            │
│       │  QEMU   │───────►│  Host Kernel │───────►│  Physical   │            │
│       │         │ ioctl  │  vhost-net   │        │  NIC        │            │
│       └─────────┘        │  (内核态)     │        │             │            │
│                          └─────────────┘        └─────────────┘            │
│                                                                             │
│  数据路径: VM → QEMU → 内核 vhost-net → 内核协议栈 → NIC                   │
│  问题: 每个包都要经过内核协议栈，上下文切换开销大                              │
│                                                                             │
│  阶段 2: vhost-user — 绕过宿主机内核                                        │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│       ┌─────────┐                                                           │
│       │  VM     │                                                           │
│       └────┬────┘                                                           │
│            │ virtqueue (共享内存)                                           │
│            ▼                                                                │
│       ┌─────────┐        ┌─────────────┐        ┌─────────────┐            │
│       │  QEMU   │  Unix  │  vhost-user │  DPDK  │  Physical   │            │
│       │         │ socket │  进程        │  PMD   │  NIC        │            │
│       │         │ (控制) │  (用户态)     │ (直通) │             │            │
│       └─────────┘        └──────┬──────┘        └─────────────┘            │
│                                 │                                           │
│                          ┌──────┴──────┐                                    │
│                          │  Host 用户态  │                                    │
│                          │  不经过内核!  │                                    │
│                          └─────────────┘                                    │
│                                                                             │
│  数据路径: VM → 共享内存 → vhost-user 进程 → DPDK PMD → NIC                │
│  改进: 包处理完全在用户态，绕过内核协议栈，零拷贝                            │
│  问题: Host CPU 仍需逐包处理 virtqueue dequeue/enqueue                      │
│                                                                             │
│  阶段 3: VDPA — 绕过宿主机 CPU                                             │
│  ────────────────────────────────────                                       │
│                                                                             │
│       ┌─────────┐                                                           │
│       │  VM     │                                                           │
│       └────┬────┘                                                           │
│            │ virtqueue (共享内存)                                           │
│            ▼                                                                │
│       ┌─────────┐                                                           │
│       │  QEMU   │───────► 控制面: ioctl 配置 virtqueue 地址 (仅初始化)       │
│       └─────────┘                                                           │
│                          │                                                   │
│                          ▼                                                   │
│       ┌─────────────────────────────────────┐                              │
│       │         DPU / SmartNIC              │                              │
│       │  ┌─────────────────────────────────┐ │                              │
│       │  │  Hardware Virtqueue Walker      │ │                              │
│       │  │  (DMA 直读 VM 内存中的 vring)    │ │                              │
│       │  └──────────────┬──────────────────┘ │                              │
│       │                 │                     │                              │
│       │                 ▼                     │                              │
│       │  ┌─────────────────────────────────┐ │                              │
│       │  │     Hardware DMA Engine         │ │                              │
│       │  │     (virtqueue → NIC 直通)      │ │                              │
│       │  └──────────────┬──────────────────┘ │                              │
│       └────────────────┼────────────────────┘                              │
│                        │                                                    │
│                        ▼                                                    │
│                 ┌─────────────┐                                             │
│                 │  Physical   │                                             │
│                 │  NIC (HW)   │                                             │
│                 └─────────────┘                                             │
│                                                                             │
│  数据路径: VM → DPU 硬件 DMA → NIC (Host CPU 不参与!)                      │
│  优势: Host CPU 完全不碰数据包，virtqueue 由硬件管理                         │
│                                                                             │
│  三阶段对比:                                                                 │
│  ┌────────────┬──────────────┬──────────────┬──────────────┐               │
│  │            │  阶段 1      │  阶段 2      │  阶段 3      │               │
│  │            │  vhost-net   │  vhost-user  │  VDPA        │               │
│  ├────────────┼──────────────┼──────────────┼──────────────┤               │
│  │ 绕过内核?  │  否          │  是          │  是          │               │
│  │ 绕过 CPU?  │  否          │  否          │  是          │               │
│  │ 包处理者   │  内核        │  Host CPU    │  DPU 硬件    │               │
│  │ 数据拷贝   │  多次        │  零拷贝      │  DMA 直通    │               │
│  └────────────┴──────────────┴──────────────┴──────────────┘               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 VDPA vs vhost-user vs KNI

| 特性         | KNI        | vhost-user     | VDPA              |
| ------------ | ---------- | -------------- | ----------------- |
| **数据路径** | 内核网络栈 | 用户态 DPDK    | 硬件 DMA          |
| **CPU 参与** | 每次操作   | virtqueue 管理 | 仅控制平面        |
| **延迟**     | 高 (~50μs) | 中 (~5-10μs)   | 低 (~3-5μs)       |
| **吞吐量**   | 受限       | 高             | 线速              |
| **功能**     | 完整内核栈 | 灵活           | 受硬件限制        |
| **部署**     | 简单       | 中等           | 需要 DPU/SmartNIC |

### 1.3 VDPA 支持的设备类型

| 设备类型        | 说明          | 硬件厂商                |
| --------------- | ------------- | ----------------------- |
| **virtio-net**  | 网络 I/O 加速 | Mellanox, Intel, NVIDIA |
| **virtio-blk**  | 块设备加速    | Mellanox, Intel         |
| **virtio-scsi** | SCSI 加速     | 较少                    |

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

// 核心结构 (simplified, kernel 6.x)
struct vdpa_device {
    struct device dev;              // Linux 设备模型
    const struct vdpa_config_ops *config;  // 配置操作
    struct vdpa_callback *event_cb; // 事件回调
    unsigned int nvqs;              // virtqueue 数量
    unsigned int ngroups;           // virtqueue group 数
    struct device *dma_dev;         // DMA 设备
    bool use_va;                    // 是否使用 VA 映射
    bool balanced;                  // 是否支持中断平衡
};

// vdpa config 操作接口 (kernel 6.x, simplified)
struct vdpa_config_ops {
    // 设备生命周期
    int (*set_vq_address)(struct vdpa_device *vdev, u16 idx,
                          u64 desc_area, u64 driver_area, u64 device_area);
    int (*set_vq_num)(struct vdpa_device *vdev, u16 num);
    void (*set_vq_ready)(struct vdpa_device *vdev, u16 idx, bool ready);
    bool (*get_vq_ready)(struct vdpa_device *vdev, u16 idx);
    int (*set_vq_state)(struct vdpa_device *vdev, u16 idx,
                         const struct vdpa_vq_state *state);
    int (*get_vq_state)(struct vdpa_device *vdev, u16 idx,
                        struct vdpa_vq_state *state);
    u16 (*get_vq_num_max)(struct vdpa_device *vdev);

    // 设备配置
    u64 (*get_device_features)(struct vdpa_device *vdev);
    int (*set_driver_features)(struct vdpa_device *vdev, u64 features);
    void (*get_config)(struct vdpa_device *vdev, void *config,
                       unsigned int size);
    void (*set_config)(struct vdpa_device *vdev, const void *config,
                       unsigned int size);
    u8 (*get_status)(struct vdpa_device *vdev);
    void (*set_status)(struct vdpa_device *vdev, u8 status);

    // DMA 映射 (IOMMU)
    int (*set_map)(struct vdpa_device *vdev,
                   struct vdpa_iova_range *iova_range);
    int (*dma_map)(struct vdpa_device *vdev, u64 iova, u64 size,
                   u64 pa, u32 perm, void *opaque);
    int (*dma_unmap)(struct vdpa_device *vdev, u64 iova, u64 size);

    // 中断回调
    void (*set_vq_cb)(struct vdpa_device *vdev, u16 idx,
                      struct vdpa_callback *cb);
    void (*set_vq_irq)(struct vdpa_device *vdev, u16 idx,
                       int fd, int vector);

    // 厂商特定
    int (*reset)(struct vdpa_device *vdev);
    u32 (*get_vendor_id)(struct vdpa_device *vdev);
    u32 (*get_device_id)(struct vdpa_device *vdev);
};
```

### 3.2 mlx5 VDPA 驱动

```c
// drivers/net/ethernet/mellanox/mlx5_vdpa/

// mlx5 VDPA 设备结构 (simplified)
struct mlx5_vdpa_dev {
    struct vdpa_device vdev;         // 继承 vdpa_device

    struct pci_dev *pdev;           // PCIe 设备
    struct mlx5_core_dev *mdev;     // mlx5 核心设备

    // virtqueue (removed duplicate field)
    struct mlx5_vdpa_virtqueue *vqs;
    int max_vqs;

    // 共享内存 (MR = Memory Region, for DMA)
    struct mlx5_vdpa_mr mr;

    // 工作队列
    struct workqueue_struct *cb_wq;
};

// 设置 virtqueue 地址
static int
mlx5_vdpa_set_vq_address(struct vdpa_device *vdev,
                          u16 idx,
                          u64 desc_area, u64 driver_area, u64 device_area)
{
    struct mlx5_vdpa_dev *mvdev = to_mlx5_vdpa_dev(vdev);
    struct mlx5_vdpa_virtqueue *mvq = &mvdev->vqs[idx];

    // 转换 GPA 到 HPA (via IOMMU / STE table)
    mvq->desc_addr = mlx5_vdpa_gpa2hpa(mvdev, desc_area);
    mvq->driver_addr = mlx5_vdpa_gpa2hpa(mvdev, driver_area);
    mvq->device_addr = mlx5_vdpa_gpa2hpa(mvdev, device_area);

    // 配置硬件 virtqueue (program mlx5 hardware)
    return mlx5_vdpa_create_virtqueue(mvdev, mvq);
}

// 获取设备特性
static u64
mlx5_vdpa_get_features(struct vdpa_device *vdev)
{
    u64 features = 0;

    // virtio-net 特性 (using kernel macro)
    features |= BIT_ULL(VIRTIO_NET_F_CSUM);
    features |= BIT_ULL(VIRTIO_NET_F_GUEST_CSUM);
    features |= BIT_ULL(VIRTIO_NET_F_MAC);
    features |= BIT_ULL(VIRTIO_NET_F_GUEST_TSO4);
    features |= BIT_ULL(VIRTIO_NET_F_GUEST_TSO6);
    features |= BIT_ULL(VIRTIO_F_RING_INDIRECT_DESC);
    features |= BIT_ULL(VIRTIO_F_RING_EVENT_IDX);
    features |= BIT_ULL(VIRTIO_NET_F_MRG_RXBUF);
    features |= BIT_ULL(VIRTIO_F_ACCESS_PLATFORM);
    features |= BIT_ULL(VIRTIO_F_VERSION_1);

    return features;
}

// DMA 映射
static int
mlx5_vdpa_dma_map(struct vdpa_device *vdev, unsigned int asid,
                  u64 iova, u64 size, u64 pa, u32 perm, void *opaque)
{
    struct mlx5_vdpa_dev *dev = to_mlx5_vdpa_dev(vdev);

    // 在硬件中配置 IOVA → PA 映射 (via mlx5 MR key)
    return mlx5_vdpa_create_mr(mvdev, iova, size, pa, perm);
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
    config.mtu = cpu_to_le16(net->mtu);
    config.max_virtqueue_pairs = cpu_to_le16(net->mvdev.max_vqs / 2);

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
# 方式一：内核 vhost-vdpa 模式 (推荐，最常用)
# 直接连 /dev/vhost-vdpa/vhost-vdpa0，无需额外进程
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -enable-kvm \
    -netdev type=vhost-vdpa,vdpa-dev=/dev/vhost-vdpa/vhost-vdpa0,id=net0 \
    -device virtio-net-pci,netdev=net0,mac=00:11:22:33:44:55

# 方式二：vhost-user-vdpa 模式 (用户态 daemon)
# 通过 Unix socket 与用户态 VDPA 守护进程通信
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -enable-kvm \
    -chardev socket,id=char0,path=/var/run/vdpa/vdpa0.sock \
    -netdev type=vhost-user,id=net0,chardev=char0 \
    -device virtio-net-pci,netdev=net0,mac=00:11:22:33:44:55
```

> [!note] 两种模式对比
>
> - **内核模式**：QEMU 直接打开 `/dev/vhost-vdpa/N`，通过内核 ioctl 配置 VDPA 设备，简单高效
> - **用户态模式**：通过 vhost-user 协议与用户态 VDPA 守护进程（如 DPDK vdpa example）通信，灵活但多一层

### 4.2 vhost-user-vdpa 架构

```c
// QEMU 中的 vhost-vdpa 实现 (hw/virtio/vhost-vdpa.c)

struct vhost_vdpa {
    int device_fd;                 // /dev/vhost-vdpa/vhost-vdpaN 句柄
    uint32_t max_queues;           // 设备支持的最大队列数
    uint64_t features;             // 设备特性
    struct vhost_dev dev;          // vhost 公共设备
    bool shadow_vqs_enabled;       // 是否启用影子 virtqueue
};

// 打开 VDPA 设备
static int
vhost_vdpa_open(struct vhost_vdpa *v)
{
    // 打开具体的 VDPA 设备节点 (不是通用的 /dev/vhost-vdpa)
    v->device_fd = open("/dev/vhost-vdpa/vhost-vdpa0", O_RDWR);
    if (v->device_fd < 0) {
        error_report("Cannot open /dev/vhost-vdpa/vhost-vdpa0: %s",
                     strerror(errno));
        return -errno;
    }

    // 获取设备特性
    if (ioctl(v->device_fd, VHOST_GET_FEATURES, &v->features) < 0) {
        error_report("Cannot get features: %s", strerror(errno));
        close(v->device_fd);
        return -errno;
    }

    return 0;
}
```

### 4.3 完整使用场景：VM 网络收发全流程

下面用一个完整场景串联 VDPA 的所有组件，帮助理解从 VM 启动到数据收发的全过程。

**场景设定**：一台物理服务器，插着 NVIDIA BlueField-2 DPU（SmartNIC），上面跑一个 VM，VM 用 virtio-net 收发网络包。

```
硬件拓扑
══════════════════════════════════════════════════════════════════════════════

    ┌─────────────────────────────────────────────────────────────────────────┐
    │                        物理服务器 (Host)                                │
    │                                                                         │
    │  ┌───────────────────────┐         ┌──────────────────────────────────┐  │
    │  │       QEMU            │         │    NVIDIA BlueField-2 DPU       │  │
    │  │                       │         │    (SmartNIC, PCIe 连接)         │  │
    │  │  ┌─────────────────┐  │         │                                  │  │
    │  │  │  VM (Guest)     │  │         │  ┌──────────────────────────┐   │  │
    │  │  │                 │  │  VFIO   │  │  DPU ARM Core            │   │  │
    │  │  │  virtio-net drv │  │◄────────┤  │  ┌────────────────────┐  │   │  │
    │  │  │  Guest 内存      │  │  ioctl  │  │  │  mlx5_vdpa 驱动   │  │   │  │
    │  │  │  (vring 在这)   │  │  配置    │  │  └────────┬───────────┘  │   │  │
    │  │  │                 │  │         │  │           │ 控制寄存器     │   │  │
    │  │  └────────┬────────┘  │         │  │           ▼               │   │  │
    │  │           │ GPA       │         │  │  ┌────────────────────┐  │   │  │
    │  │           │           │         │  │  │  硬件 DMA Engine   │  │   │  │
    │  │           │           │         │  │  │  Virtqueue Walker  │  │   │  │
    │  │           │           │         │  │  │  CQ (完成队列)     │  │   │  │
    │  │           │           │         │  │  └────────┬───────────┘  │   │  │
    │  └───────────┼───────────┘         │  └───────────┼──────────────┘   │  │
    │              │                     │              │                   │  │
    │              │    IOMMU 映射       │         DMA 直接读写            │  │
    │              │    GPA → HPA        │         (绕过 Host CPU)         │  │
    │              │                     │              │                   │  │
    │              └─────────────────────┘              │                   │  │
    │                                                   ▼                   │  │
    │                                          ┌────────────────┐           │  │
    │                                          │  DPU 外部网口   │           │  │
    │                                          │  (100Gbps)     │           │  │
    │                                          └───────┬────────┘           │  │
    └──────────────────────────────────────────────────┼──────────────────────┘
                                                     │
                                               外部网络 (Internet/DCN)
```

```
阶段 1: VM 启动 — 设备发现与控制面初始化
══════════════════════════════════════════════════════════════════════════════

    VM (Guest)                    QEMU (Host)              内核 VDPA 框架          DPU 硬件
    ──────────                    ──────────              ───────────────          ────────

    ① virtio-net 驱动探测
       发现 virtio-net PCI 设备
       读取 PCI 配置空间
              │
              │ MMIO 读 PCI config
              ▼
                                    QEMU 拦截 PCI 配置空间读
                                    调用 vhost-vdpa 后端
                                              │
                                              │ open("/dev/vhost-vdpa/vhost-vdpa0")
                                              ▼
                                                                    内核创建
                                                                    vhost_vdpa 结构
                                                                    ioctl: VHOST_GET_FEATURES
                                                                              │
                                                                              │ VFIO 配置 DPU
                                                                              ▼
                                                                    DPU 返回特性位
                                                                    (VIRTIO_F_RING_INDIRECT_DESC,
                                                                     VIRTIO_F_MRG_RXBUF, ...)

    ② 特性协商
       Guest 选择支持的特性子集
       写回 PCI 配置空间
              │
              │ MMIO 写
              ▼
                                    ioctl: VHOST_SET_FEATURES
                                              │
                                              ▼
                                                                    设置 DPU 特性
                                                                    (通过 VFIO 写寄存器)

    ③ virtqueue 配置
       Guest 在内存中分配 vring
       (desc table + avail ring + used ring)
       写队列地址到 PCI 配置空间
              │
              │ MMIO 写 desc/avail/used GPA
              ▼
                                    ioctl: VHOST_SET_VRING_ADDR
                                    ioctl: VHOST_SET_VRING_NUM
                                    ioctl: VHOST_SET_VRING_BASE
                                              │
                                              ▼
                                                                    ioctl: VDPA_SET_VRING_ENABLE
                                                                              │
                                                                              │ VFIO 写 DPU 寄存器
                                                                              ▼
                                                                    DPU 硬件记录:
                                                                    - vring desc/avail/used GPA
                                                                    - 通过 IOMMU 转换为 HPA
                                                                    - 启动 Virtqueue Walker

    ④ Driver OK
       Guest 写 DRIVER_OK 状态位
              │
              ▼
                                    ioctl: VHOST_VDPA_SET_STATUS
                                              │
                                              ▼
                                                                    DPU 开始工作！
                                                                    DMA Engine 就绪
                                                                    Virtqueue Walker 开始轮询 avail ring
```

```
阶段 2: VM 发送数据包 (TX)
══════════════════════════════════════════════════════════════════════════════

    VM (Guest)                              DPU 硬件                    外部网络
    ──────────                              ────────                    ────────

    ① Guest 构造数据包
       调用 virtio_net send()
              │
              ▼
    ② 填充 vring descriptor chain
       ┌──────────────────────────────────────────────────────┐
       │  desc[0]: addr=GPA_0, len=10, flags=NEXT      ← hdr│
       │  desc[1]: addr=GPA_1, len=1514, flags=WRITE     ← pkt│
       │  avail.idx++   (avail ring)                        │
       └──────────────────────────────────────────────────────┘
              │
              │  ③ Kick: 写 PCI doorbell (MMIO)
              │     (通知"有新包")
              ▼
                                                            ┌──────────────────┐
    ┌─────────────────────────────────────────────────────► │  Virtqueue Walker │
    │  ④ DPU 检测到 avail.idx 变化                        │  通过 IOMMU 转换  │
    │     (DMA 读取 avail ring, 发现新描述符)               │  GPA → HPA        │
    │                                                       └────────┬─────────┘
    │  ⑤ DMA Engine:                                        │
    │     读 desc[0]: 取 virtio_net_hdr (GPA_0 → HPA_0)    │
    │     读 desc[1]: 取数据包内容 (GPA_1 → HPA_1)         │
    │                                                       │
    │  ⑥ DPU 硬件处理:                                      │
    │     - 解析 virtio_net_hdr                             │
    │     - csum offload (如果协商了)                        │
    │     - TSO 分片 (如果协商了)                            │
    │     - 封装成以太网帧                                   │
    │                                                       │
    │  ⑦ 发送到 DPU 外部网口 ────────────────────────────────────────────► 外部网络
    │
    │  ⑧ 更新 used ring (DMA 写入 Guest 内存):
    │     used_ring[idx] = { id=0, len=1524 }
    │     used.idx++
    │
    │  ⑨ 触发 MSI-X 中断 (可选, 取决于是否协商了 EVENT_IDX)
    │
    ▼
    ⑩ Guest virtio-net 驱动收到中断 (或轮询)
       读取 used ring, 回收 descriptor
       TX 完成!

    注意: 整个过程 Host CPU 完全不参与数据路径
          QEMU 在 ③ 之后就没有数据面操作了
```

```
阶段 3: VM 接收数据包 (RX)
══════════════════════════════════════════════════════════════════════════════

    外部网络                    DPU 硬件                              VM (Guest)
    ────────                    ────────                              ──────────

    ① 物理网口收到以太网帧
       │
       ▼
    ② DPU DMA Engine 从 NIC RX 队列取出帧
       │
       │  ③ DPU 查找 Guest 的 avail ring
       │     找到空闲的 descriptor
       │     (Guest 之前预分配好了)
       │
       │  ④ DMA 写入 Guest 内存:
       │     写 desc[N].addr (GPA → HPA):
       │       - virtio_net_hdr (10 bytes)
       │       - 实际数据包 (如 1514 bytes)
       │
       │  ⑤ 更新 used ring:
       │     used_ring[idx] = { id=N, len=1524 }
       │     used.idx++
       │
       │  ⑥ 触发 MSI-X 中断 ──────────────────────────────────────────►  Guest
       │                                                              收到中断
    ┌──┘                                                              │
    │                                                                 ▼
    │  ⑦ Guest virtio-net 驱动处理中断                              ⑧ 读取 used ring
    │     (或 NAPI 轮询)                                                找到已填充的 descriptor
    │                                                                 ⑨ 从 Guest 内存取数据
    │                                                                    传递给网络协议栈
    │
    │  ⑩ Guest 补充新的空闲 descriptor 到 avail ring
    │     (为下一批收包做准备)
    │
    │  ⑪ Kick: 写 PCI doorbell (通知 DPU 有新的空闲 buffer)
    │
    ▼
    循环继续...

    注意: 同样 Host CPU 完全不参与
```

```
阶段 4: VM 关闭 / Live Migration
══════════════════════════════════════════════════════════════════════════════

    VM (Guest)                    QEMU (Host)              DPU 硬件
    ──────────                    ──────────              ────────

    正常关闭:
    ─────────

    ① Guest 写 DEVICE_RESET 或 QEMU 发起关闭
              │
              ▼
                                    ioctl: VDPA_SET_VRING_ENABLE(0)
                                              │
                                              ▼
                                                            DPU 停止 Virtqueue Walker
                                                            DMA Engine 停止
                                                            释放 IOMMU 映射

    Live Migration (热迁移):
    ──────────────────────

    ① 源端: ioctl: VDPA_SUSPEND
              │
              ▼
                                    源 DPU 停止 DMA
                                    获取 last_avail_idx
                                    获取 last_used_idx
              │
              │  ② 迁移 VM 内存 + 设备状态
              ▼
    目标 QEMU ◄─────────────────── 迁移通道 ◄───────────────── 源 QEMU
              │
              ▼
    ③ 目标: ioctl: VDPA_SET_VRING_ENABLE(1)
                                    ioctl: VDPA_SET_VRING_STATE
                                              │
                                              ▼
                                                            目标 DPU 从
                                                            last_avail_idx 恢复
                                                            DMA Engine 重新启动
```

```
对比: 同一场景下 vhost-user (软件) vs VDPA (硬件)
══════════════════════════════════════════════════════════════════════════════

  vhost-user (软件模式):
  ─────────────────────

    VM Guest                         vhost-user 进程 (Host CPU)
    ─────────                        ────────────────────────

    ① Guest 写 avail ring + kick
              │
              │  VMEXIT / eventfd 通知
              ▼
    ────────────────────────────────────────────────────────
    │  Host CPU 唤醒 vhost-user 进程                      │
    │                                                       │
    │  ② 读取 avail ring (从共享内存)                      │
    │  ③ DMA prefetch 数据包到 Host 内存                   │
    │  ④ 软件解析 virtio_net_hdr                           │
    │  ⑤ 软件封装以太网帧                                  │
    │  ⑥ rte_eth_tx_burst() 发送到物理网卡                  │
    │  ⑦ 更新 used ring (写共享内存)                       │
    │  ⑧ 写 eventfd 通知 Guest                             │
    ────────────────────────────────────────────────────────
              │
              ▼
    ⑨ Guest 收到 used ring 更新

    瓶颈: 每个包都要 Host CPU 处理 → 大包量时 CPU 100%


  VDPA (硬件模式):
  ────────────────

    VM Guest                         DPU 硬件 (SmartNIC)
    ─────────                        ──────────────────

    ① Guest 写 avail ring + kick
              │
              │  VMEXIT → QEMU 写 doorbell → DPU
              ▼
    ────────────────────────────────────────────────────────
    │  DPU 硬件自主完成:                                    │
    │                                                       │
    │  ② Virtqueue Walker 读 avail ring                    │
    │  ③ DMA Engine 直接从 VM 内存读数据                   │
    │  ④ 硬件解析 + 封装 + 发送                            │
    │  ⑤ DMA 写 used ring 到 VM 内存                      │
    │  ⑥ MSI-X 中断通知 Guest                              │
    ────────────────────────────────────────────────────────
              │
              ▼
    ⑦ Guest 收到 used ring 更新

    优势: Host CPU 完全不处理数据包 → 释放给其他 VM/业务
```

> [!note] 关键理解点
>
> 1. **控制面和数据面分离**：QEMU/CPU 只在阶段 1（初始化）工作，阶段 2/3（收发数据）完全由 DPU 硬件完成
> 2. **IOMMU 是桥梁**：Guest 用 GPA（Guest 物理地址），DPU 通过 IOMMU 将 GPA 转为 HPA（Host 物理地址），才能 DMA 读写
> 3. **vring 格式不变**：DPU 直接读取标准 virtio vring，不需要 VM 做任何修改，Guest 完全不知道后端是软件还是硬件
> 4. **VMEXIT 仍然存在**：kick doorbell 和 MSI-X 中断仍需 VMEXIT，但频率远低于数据包速率（可用 EVENT_IDX 机制减少中断）
> 5. **Live Migration 支持**：通过 `VDPA_SUSPEND`/`VDPA_RESUME` 保存/恢复 virtqueue 状态，是生产可用的重要特性

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
// lib/vhost/rte_vdpa.h  (DPDK 23.11+)

// VDPA 设备结构
struct rte_vdpa_device {
    rte_iova_t device_addr;       // 设备 PCI 地址
    struct rte_device *rte_dev;   // DPDK 设备
    const char *name;             // 设备名称
    uint32_t max_queue_num;       // 最大队列数
    uint64_t features;            // 支持的特性
    struct rte_vdpa_dev_ops *ops; // 操作回调
    void *priv;                   // 驱动私有数据
};

// VDPA 操作接口
struct rte_vdpa_dev_ops {
    // 获取设备配置空间
    int (*get_config)(int vid, uint8_t *config, uint32_t size);

    // 获取/设置特性
    int (*get_features)(int vid, uint64_t *features);
    int (*set_features)(int vid, uint64_t features);

    // virtqueue 配置
    int (*setup_vring)(int vid, int qid, bool is_enable,
                       struct rte_vhost_vring *vring);

    // 获取 virtqueue 状态 (用于 live migration)
    int (*get_vq_state)(int vid, uint16_t qid,
                        struct rte_vdpa_vq_state *state);

    // DMA 映射/解映射
    int (*dma_map)(int vid, uint64_t iova, uint64_t size, void *va);
    int (*dma_unmap)(int vid, uint64_t iova, uint64_t size);

    // 获取设备统计信息
    int (*get_stats)(int vid, int qid, struct rte_vdpa_stat *stats,
                     unsigned int n);
    int (*reset_stats)(int vid, int qid);

    // 获取通知区域 (用于映射 doorbell)
    int (*get_notify_area)(int vid, int qid,
                           struct rte_vdpa_notify_area *area);
};
```

> [!note] DPDK vdpa API 说明
>
> - 操作函数的第一个参数是 `vid`（vhost device ID），不是设备结构体指针
> - `setup_vring` 统一负责设置/禁用 virtqueue，不区分 setup/start/stop
> - 不存在 `poll_completion` 等函数 — VDPA 数据路径由硬件完成，软件无需轮询

### 5.3 使用 DPDK vdpa 库

```c
// DPDK VDPA 使用示例 (基于 DPDK vdpa sample)

#include <rte_eal.h>
#include <rte_vdpa.h>
#include <rte_vhost.h>

// VDPA 设备上下文
struct vdpa_context {
    struct rte_vdpa_device *vdpa_dev;
    int vid;                       // vhost device ID
    uint32_t max_vq_num;           // 最大队列数
};

// vhost-user new_device 回调
static int
vdpa_new_device(int vid)
{
    struct rte_vdpa_device *dev;
    struct vdpa_context *ctx;
    uint64_t features;

    // 通过 vid 查找对应的 VDPA 设备
    dev = rte_vdpa_get_device(rte_vhost_get_vdpa_device_id(vid));
    if (!dev) {
        RTE_LOG(ERR, VDPA, "No VDPA device for vid %d\n", vid);
        return -1;
    }

    // 获取设备特性并协商
    if (dev->ops->get_features(vid, &features) < 0) {
        RTE_LOG(ERR, VDPA, "Failed to get features\n");
        return -1;
    }

    // 获取最大队列数
    ctx->max_vq_num = rte_vdpa_get_queue_num(dev);
    RTE_LOG(INFO, VDPA, "VDPA device: max queues = %u\n", ctx->max_vq_num);

    // virtqueue 配置由 setup_vring 回调自动完成
    // (QEMU 在特性协商后逐个调用 setup_vring)

    return 0;
}

// vhost-user destroy_device 回调
static void
vdpa_destroy_device(int vid)
{
    // 硬件资源由 VDPA 驱动自动清理
    RTE_LOG(INFO, VDPA, "VDPA device vid=%d destroyed\n", vid);
}

// 注册 vhost-user 回调
static const struct vhost_device_ops vdpa_device_ops = {
    .new_device          = vdpa_new_device,
    .destroy_device      = vdpa_destroy_device,
    // 其他回调使用默认实现
};

// 主函数
int
main(int argc, char *argv[])
{
    // 初始化 EAL
    if (rte_eal_init(argc, argv) < 0)
        rte_exit(EXIT_FAILURE, "EAL init failed\n");

    // 注册 vhost-user socket
    const char *socket_path = "/tmp/vhost-vdpa0.sock";
    if (rte_vhost_driver_register(socket_path, 0) < 0)
        rte_exit(EXIT_FAILURE, "Socket register failed\n");

    // 设置回调
    rte_vhost_driver_callback_register(socket_path, &vdpa_device_ops);

    // 启动 vhost-user 事件循环
    // (数据路径完全由硬件处理，软件只处理控制平面事件)
    rte_vhost_driver_start(socket_path);

    // 等待退出信号...
    rte_eal_mp_wait_lcore();
    return 0;
}
```

> [!note] VDPA 与 vhost-user 软件模式的关键区别
>
> - 上面代码看起来和 vhost-user sample 几乎一样 — 这正是 VDPA 的设计意图
> - 控制平面代码（回调注册、特性协商）完全相同
> - 区别在于 `rte_vdpa_get_device()` 返回的是 VDPA 设备，其 ops 指向硬件驱动
> - 数据路径无需软件处理：没有 `rte_vhost_dequeue_burst()`，没有 `rte_vhost_enqueue_burst()`
> - 硬件通过 DMA 直接访问 VM 内存，软件只等待控制事件

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

// 硬件描述符 — 实际上就是标准 virtio vring_desc
// 硬件直接读取 VM 中的 vring，格式完全相同
struct vring_desc {
    uint64_t addr;         // 缓冲区地址 (GPA)
    uint32_t len;          // 缓冲区长度
    uint16_t flags;        // VRING_DESC_F_* 标志
    uint16_t next;         // 链式下一个 desc 索引
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

> [!note] 数据来源说明
> 以下数据为典型量级参考，综合自 NVIDIA/Mellanox 官方白皮书和社区 benchmark 报告。
> 实际性能取决于具体硬件型号、固件版本、包大小分布和测试配置。

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

| 场景          | 方案        | 吞吐量         | CPU 利用率 | 加速比 |
| ------------- | ----------- | -------------- | ---------- | ------ |
| **64B 小包**  | vhost-user  | 5-10 Mpps      | ~100%      | 1x     |
| **64B 小包**  | VDPA (mlx5) | 20-30 Mpps     | <10%       | 3-5x   |
| **Jumbo 帧**  | vhost-user  | 10-15 Gbps     | ~80%       | 1x     |
| **Jumbo 帧**  | VDPA (mlx5) | 80-100 Gbps    | <15%       | 5-8x   |
| **存储 IOPS** | vhost-blk   | 200K IOPS      | ~90%       | 1x     |
| **存储 IOPS** | VDPA (mlx5) | 800K-1.2M IOPS | <20%       | 4-6x   |

> [!note] 关于 64B 小包性能
> 原稿中 VDPA 64B 吞吐量标为 50 Mpps 过于乐观。实际在 ConnectX-6/7 上，纯硬件转发（无软件开销）在 64B 场景通常为 20-30 Mpps，主要瓶颈在 PCIe 带宽和硬件 desc 处理流水线深度。50 Mpps 通常需要多端口聚合或特殊硬件。

---

## 8. VDPA 部署

### 8.1 硬件要求

| 组件             | 要求                                        |
| ---------------- | ------------------------------------------- |
| **DPU/SmartNIC** | Mellanox ConnectX-6/7, NVIDIA BlueField-2/3 |
| **驱动**         | mlx5_core, mlx5_vdpa (Linux kernel 5.10+)   |
| **固件**         | 最新 VDPA 固件                              |
| **QEMU**         | 6.0+                                        |
| **DPDK**         | 21.02+                                      |

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
    -netdev type=vhost-vdpa,vdpa-dev=/dev/vhost-vdpa/vhost-vdpa0,id=net0 \
    -device virtio-net-pci,netdev=net0,mac=00:11:22:33:44:55 \
    -object memory-backend-file,id=mem0,size=4G,share=on \
    -machine q35,memory-backend=mem0

# 5. 在 Guest 内使用标准 virtio-net 驱动
# (无需特殊驱动)
```

---

## 9. 小结

本章核心要点：

1. **VDPA 背景**：将 vhost 数据路径卸载到硬件（DPU/SmartNIC），CPU 仅参与控制平面（特性协商、virtqueue 配置），数据平面延迟 ~3-5μs。

2. **演进路径**：纯软件 vhost → vhost-user (用户态) → VDPA (硬件卸载)。VDPA 保留了 virtio 兼容性，Guest 无需感知后端是软件还是硬件。

3. **架构**：控制平面通过 VFIO/PCIe 配置 DPU，数据平面由 DPU 硬件（DMA Engine + Virtqueue Walker）自主处理。硬件直接读取 VM 中的标准 vring 描述符。

4. **内核 VDPA 驱动**：`vdpa_device` 抽象层 + 厂商特定驱动（`mlx5_vdpa`），通过 `vdpa_config_ops` 提供统一的设备管理和 DMA 映射接口。

5. **QEMU 支持**：两种模式 — 内核模式（直接打开 `/dev/vhost-vdpa/N`）和用户态模式（通过 vhost-user socket）。

6. **DPDK vdpa 库**：`rte_vdpa_device` + `rte_vdpa_dev_ops`，操作函数以 `vid` 为参数，与 vhost-user 控制平面代码高度相似，区别在于数据路径由硬件完成。

7. **硬件 virtqueue**：DPU 内部实现标准的 desc/avail/used 环处理逻辑和 DMA 引擎，格式与 virtio 规范一致，直接从 VM 内存 DMA 读写数据。

8. **性能优势**：小包 3-5x 加速（20-30 Mpps vs 5-10 Mpps），CPU 利用率降至 <10%，Jumbo 帧可达 80-100 Gbps 线速。性能取决于具体硬件型号和测试配置。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch19b-dpu-smartnic|第十九章补充：DPU/SmartNIC 基础]]将解释 DPU 是什么——VDPA 背后的硬件载体、网卡上跑 Linux 是什么体验。

---

> [!tip] 参考文献
>
> - "VDPA 规范", https://www.kernel.org/doc/html/latest/userspace-api/vdpa.html
> - Intel, "DPDK Vhost", https://doc.dpdk.org/guides/prog_guide/vhost_lib.html
> - Mellanox, "mlx5 VDPA driver", https://docs.nvidia.com/networking/category/mlx5drivers
> - "vDPA 概述", https://www.redhat.com/en/blog/introduction-vdpa
