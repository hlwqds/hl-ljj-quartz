---
title: "DPDK 深度探索 ch34：热迁移"
date: 2026-04-10 12:30:00
tags: [dpdk, live-migration, vm, checkpoint, restore, pre-copy, virtio]
description: "深入解析 DPDK 热迁移：VM 热迁移机制、Checkpoint/Restore、DPDK 状态保存与恢复"
---

# DPDK 深度探索 ch34：热迁移

> [!abstract] 核心要点
> 热迁移是云环境的核心能力。本章深入解析 VM 热迁移机制、CRIU 技术、DPDK 状态保存与恢复。

## 1. 热迁移概述

### 1.1 什么是热迁移

```
┌─────────────────────────────────────────────────────────────┐
│                    Live Migration                          │
│                                                              │
│  Source Host                        Target Host             │
│  ┌─────────────────┐               ┌─────────────────┐       │
│  │    Running VM   │ ─────────────▶│    Running VM   │       │
│  │                 │   (无停机)    │                 │       │
│  │  CPU: 100%      │ ─────────────▶│  CPU: 100%      │       │
│  │  Mem: 4GB       │ ─────────────▶│  Mem: 4GB       │       │
│  │  Disk: 100GB    │               │                 │       │
│  └─────────────────┘               └─────────────────┘       │
│                                                              │
│  VM 在迁移过程中继续运行                                     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 热迁移类型

| 类型          | 停机时间 | 复杂度 | 适用      |
| ------------- | -------- | ------ | --------- |
| **Offline**   | 分钟级   | 低     | 无状态 VM |
| **Pre-copy**  | 秒级     | 中     | 有状态 VM |
| **Post-copy** | 毫秒级   | 高     | 大内存 VM |
| **Hybrid**    | 毫秒级   | 高     | 通用      |

## 2. Pre-copy 迁移

### 2.1 流程

```
┌─────────────────────────────────────────────────────────────┐
│                    Pre-copy Migration                       │
│                                                              │
│  Phase 1: 迭代拷贝                                           │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  1. 启动 VM                                           │   │
│  │  2. 拷贝全部内存 (脏页)                              │   │
│  │  3. 再次拷贝 (新脏页)                                │   │
│  │  4. 重复直到脏页足够少                              │   │
│  └─────────────────────────────────────────────────────┘   │
│                            ↓                                │
│  Phase 2: Stop-and-Copy                                    │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  1. 停止 Source VM                                   │   │
│  │  2. 拷贝剩余状态 (CPU, device)                      │   │
│  │  3. 启动 Target VM                                   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 内存迭代

```c
// 脏页跟踪
struct vm_migration {
    void *vm_base;
    uint64_t total_pages;
    uint64_t dirty_pages;

    // Bitmap of dirty pages
    unsigned long *dirty_bitmap;

    // 迭代计数
    int iteration;
    uint64_t bytes_sent;
};

// 跟踪脏页
void
track_dirty_pages(struct vm_migration *mig)
{
    // 内核跟踪每个 page fault
    // 用户态通过 /proc/vmstat 获取

    FILE *f = fopen("/proc/vmstat", "r");
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        if (strstr(line, "pgpromote_")) {
            // 记录脏页
            int pfn = parse_pfn(line);
            set_bit(mig->dirty_bitmap, pfn);
        }
    }
    fclose(f);
}
```

## 3. DPDK 状态

### 3.1 需要保存的状态

```
DPDK 状态分类：

1. 内存状态
   - Hugepage 内存
   - mbuf pools
   - rte_ring

2. 网卡状态
   - TX/RX 描述符
   - MAC 地址
   - VLAN 配置
   - RSS 配置

3. Virtqueue 状态
   - 队列指针
   - available/used ring
   - 正在传输的 descriptor

4. 应用状态
   - Flow table
   - Session state
   - Counter 状态
```

### 3.2 Virtio 状态保存

```c
// 保存 Virtio 状态
struct virtio_migration_state {
    // Virtqueue 状态
    struct {
        uint16_t avail_idx;
        uint16_t used_idx;
        uint64_t desc_addr;
        uint64_t avail_addr;
        uint64_t used_addr;
    } vq[2];  // TX, RX

    // 网卡配置
    uint8_t mac[6];
    uint16_t status;
    uint16_t max_tx_queues;
    uint16_t max_rx_queues;
};

// 保存 Virtio 状态
int
virtio_save_state(int fd, struct virtio_migration_state *state)
{
    // 读取 PCI 配置
    read(fd, &state->mac, 6);

    // 读取队列配置
    for (int i = 0; i < 2; i++) {
        ioctl(fd, VHOST_GET_VRING_BASE, &state->vq[i]);
    }

    return 0;
}

// 恢复 Virtio 状态
int
virtio_restore_state(int fd, struct virtio_migration_state *state)
{
    // 恢复 PCI 配置
    write(fd, &state->mac, 6);

    // 恢复队列
    for (int i = 0; i < 2; i++) {
        ioctl(fd, VHOST_SET_VRING_BASE, &state->vq[i]);
    }

    return 0;
}
```

## 4. CRIU

### 4.1 CRRU 简介

```
CRIU (Checkpoint/Restore In Userspace):

- Linux 工具
- 可以在用户空间保存/恢复进程状态
- 支持网络、文件系统、内存等
- DPDK 应用需要特殊支持

项目地址：https://criu.org/
```

### 4.2 CRRU 基本使用

```bash
# 安装 CRRU
apt-get install criu

# 保存进程
criu dump -t <PID> -D /path/to/images --shell-job

# 恢复进程
criu restore -D /path/to/images --shell-job

# 远程迁移
criu page-server --address <target-ip> --port <port>
```

### 4.3 DPDK + CRRU

```bash
# DPDK 应用迁移需要
# 1. 启用 memfd Cain mode
criu dump -t <PID> \
    --enable-fs /mnt/hugepages \
    --root / \
    -D /path/to/images

# 2. 内存映射
criu dump -t <PID> \
    --enable-mem-track \
    -D /path/to/images
```

## 5. vhost-user 迁移

### 5.1 vhost-user 状态

```c
// vhost-user 迁移状态
struct vhost_migration_state {
    // 内存映射
    struct {
        uint64_t gpa;
        uint64_t size;
        uint64_t hva;
    } regions[16];

    // Virtqueue
    struct {
        uint64_t desc_addr;
        uint64_t avail_addr;
        uint64_t used_addr;
        uint16_t size;
        uint16_t last_avail_idx;
        uint16_t last_used_idx;
    } vqs[64];

    // 设备状态
    uint64_t features;
    uint32_t protocol_features;
};

// 保存 vhost-user 状态
static int
vhost_save_state(int fd, struct vhost_migration_state *state)
{
    // 获取内存映射
    ioctl(fd, VHOST_GET_MEM_TABLE, state->regions);

    // 获取每个队列
    for (int i = 0; i < state->num_queues; i++) {
        ioctl(fd, VHOST_GET_VRING_BASE, i, &state->vqs[i]);
    }

    return 0;
}
```

### 5.2 QEMU 迁移

```bash
# QEMU 迁移配置
# 1. 启动源 VM
qemu-system-x86_64 \
    -m 4G \
    -device virtio-net-pci,\
netdev=net0 \
    -netdev vhost-user,\
id=net0,\
chardev=char0 \
    -chardev socket,\
id=char0,\
path=/var/run/vpp/vhost.sock

# 2. 开始迁移
migrate -d tcp:target-host:4444

# 3. 监控迁移
info migrate

# 4. 迁移完成
migrate -c
```

## 6. 迁移性能

### 6.1 影响因素

```
迁移时间 = 内存大小 / 带宽 + 停机时间

关键因素：
1. 内存大小
   - 4GB VM: ~10-30 秒
   - 64GB VM: ~2-5 分钟

2. 内存变化率 (脏页率)
   - 低负载: ~1-5 MB/s
   - 高负载: ~100+ MB/s

3. 网络带宽
   - 1 Gbps: 慢
   - 10 Gbps: 快

4. CPU 负载
   - 影响迭代次数
```

### 6.2 优化

```bash
# 1. 压缩内存传输
migrate -d tcp:target-host:4444 \
    -decompress-compress tcp:localhost:4445

# 2. 使用 RDMA 传输
migrate -d rdma:target-host:4444

# 3. 内存节流
# 减少迁移对性能的影响
```

## 7. 总结

迁移流程：

```
┌─────────────────────────────────────────────────────────────┐
│                    迁移时间线                               │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Pre-copy Phase (迭代拷贝)                          │   │
│  │  - 100% 内存 → 10% 内存 → 5% 内存 → ...            │   │
│  │  - 每个迭代减少脏页                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                            ↓                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Stop-and-Copy (停止拷贝)                           │   │
│  │  - 停止源 VM                                       │   │
│  │  - 拷贝 CPU/设备状态                              │   │
│  │  - 启动目标 VM                                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                            ↓                                │
│  ┌─────────────────────────────────────────────────────┐   │
│  │  Recovery (恢复)                                    │   │
│  │  - 恢复内存映射                                    │   │
│  │  - 恢复网卡状态                                    │   │
│  │  - 恢复应用状态                                    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

DPDK 迁移挑战：

| 挑战     | 解决方案      |
| -------- | ------------- |
| 内存映射 | 使用 memfd    |
| NIC 状态 | Virtio 标准   |
| 大内存   | Pre-copy 迭代 |
| 实时性   | Post-copy     |

---

## 参考资源

- [CRIU](https://criu.org/)
- [QEMU Migration](https://wiki.qemu.org/Features/LiveMigration)
- [libvirt Migration](https://libvirt.org/migration.html)
