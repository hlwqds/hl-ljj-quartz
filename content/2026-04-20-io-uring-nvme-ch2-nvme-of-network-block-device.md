---
title: io_uring × NVMe 深度探索 Ch2：NVMe-oF 网络块设备
date: 2026-04-20 15:00:00
tags: [io_uring, NVMe, NVMe-oF, Network Storage, RDMA, TCP, Fabric, Block Device, Remote Storage, iSCSI, RoCE]
description: 深入讲解 NVMe over Fabrics 架构：RDMA/TCP 传输层、NVMe/TCP vs RDMA 对比、 initiator/target 配置、以及 io_uring 在 NVMe-oF 中的角色。
---

# io_uring × NVMe 深度探索 Ch2：NVMe-oF 网络块设备

## 1. 为什么需要 NVMe-oF

### 1.1 本地 NVMe 的局限性

```
本地 NVMe SSD 的限制：
  · 单机存储容量有限
  · 无法跨机器共享（除非通过文件系统）
  · 数据中心存储资源利用率低
  · 扩展性差

传统网络存储的局限（iSCSI / NFS）：
  · iSCSI：基于 SCSI，协议开销大
  · NFS/CIFS：文件系统协议，更大开销
  · 延迟高（通常 500us-2ms）
  · 无法发挥 NVMe SSD 的性能

理想方案：
  把 NVMe 的高性能（低延迟、高 IOPS）
  通过网络延伸到远程机器
  → NVMe over Fabrics (NVMe-oF)
```

### 1.2 NVMe-oF 架构

```
NVMe-oF 架构：

┌─────────────────────────────────────────────────────────────┐
│                        Initiator（客户端）                  │
│  ┌──────────────┐                                           │
│  │   应用        │  → 块设备访问                            │
│  │   (/dev/nvmeXn1)                                    │
│  └──────┬───────┘                                           │
│         │                                                   │
│  ┌──────▼───────┐    ┌──────────────────────────────────┐  │
│  │  NVMe Driver │    │         Fabric Network           │  │
│  │  ( initiator) │◄──►│   (RDMA / TCP / FC / Seagate)   │  │
│  └───────────────┘    └──────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                                    │
┌────────────────────────────────────▼─────────────────────────┐
│                        Target（服务端）                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  NVMe Driver (target)  │  NVMe SSD                  │  │
│  │  · 接收命令              │  · 本地 NVMe 设备           │  │
│  │  · 路由到本地 NVMe      │  · 高速存储                 │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

关键思想：
  NVMe-oF = NVMe 命令通过网络传输
  initiator 发送 NVMe SQ Entry → 网络 → target 执行 → 返回 CQE

协议栈对比：
  本地 NVMe：
    应用 → NVMe Driver → PCIe DMA → NVMe SSD

  NVMe-oF (RDMA)：
    应用 → NVMe Driver → RDMA Verbs → RDMA NIC → 网络 → RDMA NIC → RDMA Verbs → NVMe Driver → NVMe SSD

  NVMe-oF (TCP)：
    应用 → NVMe Driver → NVMe/TCP → TCP/IP → NIC → 网络 → NIC → TCP/IP → NVMe/TCP → NVMe Driver → NVMe SSD
```

---

## 2. NVMe-oF 传输层

### 2.1 支持的传输类型

```
NVMe-oF 支持的 Fabric 类型：

┌─────────────────────────────────────────────────────────────────┐
│  Fabric Type       │  传输层      │  延迟    │  带宽    │  备注    │
├─────────────────────────────────────────────────────────────────┤
│  RDMA (RoCE v2)    │  InfiniBand/ │  ~100ns  │  100Gbps │  最低延迟 │
│                    │  iWARP       │           │  (HDR)   │          │
├─────────────────────────────────────────────────────────────────┤
│  FC (Fibre Channel)│  FC-NVMe     │  ~200ns  │  64/128  │  企业存储 │
│                    │              │           │  Gbps    │          │
├─────────────────────────────────────────────────────────────────┤
│  TCP               │  NVMe/TCP    │  ~1-5us  │  100Gbps │  最灵活   │
│                    │  (RFC  Act 4)│  (+网络)  │  (Gen5)  │          │
├─────────────────────────────────────────────────────────────────┤
│  Seagate           │  Seagate     │  ?       │  ?       │  厂商私有 │
│                    │  Disclosed    │           │           │          │
└─────────────────────────────────────────────────────────────────┘

主流选择：
  · 数据中心（低延迟）：RoCE v2（首选）
  · 企业存储（兼容 FC）：FC-NVMe
  · 通用部署/云环境：NVMe/TCP（无需特殊硬件）
```

### 2.2 RDMA 传输（RoCE v2）

```
RoCE v2 (RDMA over Converged Ethernet v2)：

工作原理：
  ┌─────────────┐      ┌─────────────┐      ┌─────────────┐
  │  CPU/应用   │      │  RDMA NIC   │      │  RDMA NIC   │      │  NVMe SSD
  │             │      │  (HCA)      │      │  (HCA)      │      │
  │  GPU Direct │ ───► │  ────────►  │ ────►│  ────────►  │ ────►│
  │  Memory     │      │  RDMA Write │      │  RDMA Read  │      │  DMA to SSD
  │  Region     │      │  (0-copy)   │      │  (0-copy)   │      │
  └─────────────┘      └─────────────┘      └─────────────┘      └─────────────┘

  关键特点：
    · 数据直接从应用内存 DMA 到网络（零拷贝）
    · 绕过 CPU（CPU 不参与数据搬运）
    · 低延迟原因：无协议栈处理、无上下文切换

RDMA 操作类型：
  · RDMA Write：从本地内存写入远程内存
  · RDMA Read：从远程内存读取到本地内存
  · Send/Recv：传统的发送/接收（需要远程 CPU 参与）

NVMe-oF RDMA 流程：
  1. Initiator 构造 NVMe SQE
  2. SQE + 数据缓冲区注册到 RDMA MR（Memory Region）
  3. RDMA Send（带 IMM）发送到 target
  4. Target RDMA NIC 接收，直接 DMA 到本地 buffer
  5. Target 执行 NVMe 命令，结果通过 RDMA Write 写回
  6. Initiator RDMA NIC 接收结果
```

### 2.3 NVMe/TCP 传输（RFC 8883）

```
NVMe/TCP = NVMe 命令封装在 TCP 中传输

协议栈：
┌─────────────────────────────────────────┐
│  NVMe Command (SQE)                    │  ← NVMe 层
│  ├─ 64-byte NVMe/SQ Entry               │
│  └─ NVMe/TCP Header (Pinned)           │
├─────────────────────────────────────────┤
│  NVMe/TCP PDU                          │  ← 传输层
│  ├─ NVMe/TCP Header (H2C/C2H/Data)     │
│  ├─ 端到端数据                        │
│  └─ TCP Checksum                       │
├─────────────────────────────────────────┤
│  TCP                                   │  ← 网络层
│  ├─ Sequence / Ack                     │
│  └─ Flow Control                       │
├─────────────────────────────────────────┤
│  IP                                    │
├─────────────────────────────────────────┤
│  Ethernet                              │
└─────────────────────────────────────────┘

NVMe/TCP PDU 类型：
  · H2C (Host to Controller): NVMe Command
  · C2H (Controller to Host): NVMe Response (Completion)
  · Data: NVMe/TCP Data Out (for writes) / Data In (for reads)
  · Capsule Request: NVMe Command + Optional Data
  · Capsule Response: NVMe Completion + Optional Data
  · R2T (Ready to Data): Target → Initiator（准备接收数据）
  · Transfer I/O: 数据传输

NVMe/TCP 与 RDMA 对比：
  · 优势：无需特殊硬件，任何 TCP 网络可用
  · 劣势：CPU 参与协议处理，延迟稍高
  · 适用：云环境、混合部署、TCP 基础设施成熟
```

---

## 3. NVMe-oF 命令流

### 3.1 NVMe/TCP 命令流详解

```
NVMe/TCP 读取流程：

Initiator                                         Target
   │                                                 │
   │  1. H2C PDU (NVMe Command Read, LBA=100)        │
   │ ───────────────────────────────────────────────►│
   │     TCP Payload:                                │
   │       NVMe/TCP H2C Header                      │
   │       NVMe SQE (64 bytes)                      │
   │                                                 │
   │                                                 │  2. NVMe Driver 解析
   │                                                 │  3. 构造本地 NVMe Read
   │                                                 │
   │  4. Data In PDU (读到的数据)                    │
   │ ◄───────────────────────────────────────────────│
   │     NVMe/TCP Data In Header                    │
   │     4096 bytes 数据                             │
   │                                                 │
   │  5. C2H PDU (NVMe Completion)                  │
   │ ◄───────────────────────────────────────────────│
   │     NVMe CQE (16 bytes)                        │
   │                                                 │


NVMe/TCP 写入流程：

Initiator                                         Target
   │                                                 │
   │  1. H2C PDU (NVMe Command Write, LBA=200)     │
   │ ───────────────────────────────────────────────►│
   │     NVMe SQE + NVMe/TCP Header                 │
   │                                                 │
   │  2. R2T PDU (Ready to Receive)                 │
   │ ◄───────────────────────────────────────────────│
   │     Target 告诉 Initiator: "可以发数据了"       │
   │     NVMe/TCP R2T Header (Max R2T Size)         │
   │                                                 │
   │  3. Data Out PDU (写数据)                      │
   │ ───────────────────────────────────────────────►│
   │     NVMe/TCP Data Out Header                    │
   │     4096 bytes 数据                             │
   │                                                 │
   │  4. C2H PDU (NVMe Completion)                  │
   │ ◄───────────────────────────────────────────────│
   │     NVMe CQE                                    │
```

### 3.2 RDMA 命令流

```
NVMe/RDMA 写入流程（零拷贝）：

Initiator Memory              Target Memory
┌──────────────────┐        ┌──────────────────┐
│ SQE (64B)        │        │                  │
│ ├─ opcode=Write  │        │                  │
│ ├─ LBA=200       │        │                  │
│ └─ PRPI1=MR addr │        │                  │
├──────────────────┤        ├──────────────────┤
│ Data Buffer      │        │                  │
│ (4KB)            │ RDMA   │ Data Buffer      │
│                  │ Write  │ (4KB)            │
│                  │ ──────►│                  │
├──────────────────┤        ├──────────────────┤
│                  │        │ Local NVMe DMA   │
│                  │        ├──────────────────┤
│                  │        │ NVMe SSD         │
└──────────────────┘        └──────────────────┘

RDMA Capsule Command：
  NVMe/RDMA 把 NVMe SQE + Data 封装在单个 RDMA 操作中
  · RDMA Send (with IMM)：发送 SQE + 第一个 PRPI
  · RDMA Write (with IMM)：后续 PRPI 数据

关键点：
  · NVMe SQE 和数据缓冲区通过 RDMA MR 注册
  · RDMA NIC 直接从应用内存 DMA 数据
  · 无需拷贝、无 CPU 介入
```

---

## 4. NVMe-oF 配置实战

### 4.1 检查系统支持

```bash
# 检查内核是否支持 NVMe-oF

# 检查 NVMe/TCP 支持
grep NVME_TCP=y /boot/config-$(uname -r)
# 或者
modinfo nvme-tcp
# filename:       /lib/modules/5.15.0-generic/kernel/drivers/nvme/target/nvme-tcp.ko

# 检查 NVMe/RDMA 支持
modinfo nvme-rdma
# filename:       /lib/modules/5.15.0-generic/kernel/drivers/nvme/target/nvme-rdma.ko

# 检查 RDMA 设备
rdma link
# 或
ibstat

# 检查 NVMe-oF 启动器
ls /sys/class/nvme/
# nvme0  nvme0n1  nvme0c0n1  ...  ← 发现远程 NVMe 设备
```

### 4.2 NVMe/TCP Target 配置

```bash
# ========== Target 端（存储服务器）==========

# Step 1: 安装 nvme-cli
apt install nvme-cli
# 或
dnf install nvme-cli

# Step 2: 发现 NVMe/TCP 发现控制器
nvme discover -t tcp -a 192.168.1.100 -s 4420
# 输出示例：
# Discovery Log Entry Count: 1
# Generation Code: 1
# Address Format: ipv4
# Transport Type: TCP
# Address Family: ipv4
# Subsystem Type: NVMe
# Subsystem NQN: nqn.2014-08.org.nvmexpress:uuid:xxxxx
# Port ID: 0
# Controller ID: 0
# Port Address: 192.168.1.100
# NVMe/TCP Features: HQOS_UNKNOWN

# Step 3: 连接 NVMe/TCP 子系统
nvme connect -t tcp -n nqn.2014-08.org.nvmexpress:uuid:xxxxx \
             -a 192.168.1.100 -s 4420 -q hostnqn

# Step 4: 验证连接
nvme list
# /dev/nvme0n1   INTEL SSDPE2MX450G7   512GB   nvme0n1

# Step 5: 查看远程 NVMe 命名空间
nvme list-subsys /dev/nvme0n1
# NVM Subsystems: nvme-subsys0
# ├─ nvme0
# │  ├── Device: /dev/nvme0n1
# │  ├── Transport: tcp
# │  └── Address: 192.168.1.100:4420
```

### 4.3 使用 NVMe-CLI 管理 Target

```bash
# nvme-cli 可以配置 Linux NVMe Target（通过 configfs）

# 查看 target 配置
nvme show-topology

# 查看连接
nvme list-subsys

# 断开连接
nvme disconnect -n nqn.2014-08.org.nvmexpress:uuid:xxxxx

# 断开所有
nvme disconnect-all

# 识别远程 NVMe
nvme id-ctrl -v /dev/nvme0n1

# 查看远程日志
nvme smart-log /dev/nvme0n1
```

### 4.4 手动配置 NVMe Target（进阶）

```bash
# Linux 内核内置 NVMe Target（通过 configfs）

# 创建 target port
mkdir -p /sys/kernel/config/nvmet/subsystems/nqn.2014-08.io.spdk:nvme0
cd /sys/kernel/config/nvmet/subsystems/nqn.2014-08.io.spdk:nvme0

# 添加 namespace
mkdir namespaces/1
echo -n /dev/nvme0n1 > namespaces/1/device_path
echo 1 > namespaces/1/enable

# 创建 port（监听 TCP）
mkdir -p /sys/kernel/config/nvmet/ports/1
echo 4420 > /sys/kernel/config/nvmet/ports/1/addr_svcr
echo tcp > /sys/kernel/config/nvmet/ports/1/addr_trtype
echo 192.168.1.100 > /sys/kernel/config/nvmet/ports/1/addr_traddr

# 导出子系统
ln -s /sys/kernel/config/nvmet/subsystems/nqn.2014-08.io.spdk:nvme0 \
       /sys/kernel/config/nvmet/ports/1/subsystems/nqn.2014-08.io.spdk:nvme0

# 验证
ss -tlnp | grep 4420
# LISTEN 0 0 192.168.1.100:4420 *:*
```

---

## 5. io_uring 在 NVMe-oF 中的角色

### 5.1 io_uring + NVMe/TCP 栈

```
io_uring 在 NVMe/TCP 架构中的位置：

┌─────────────────────────────────────────────────────────────┐
│                     应用                                   │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐       │
│  │  直接 I/O  │    │ io_uring   │    │  libnvme   │       │
│  │            │    │ (异步块)    │    │ (协议库)   │       │
│  └─────┬──────┘    └─────┬──────┘    └─────┬──────┘       │
│        │                 │                 │               │
│        └────────┬────────┘                 │               │
│                 │                          │               │
└─────────────────┼──────────────────────────┼───────────────┘
                  │                          │
┌─────────────────┼──────────────────────────┼───────────────┐
│  Kernel         │                          │               │
│  ┌──────────────▼──────────┐   ┌──────────▼──────────┐  │
│  │  NVMe/TCP Driver        │   │  Socket Layer        │  │
│  │  (nvme-tcp.ko)          │◄─►│  (TCP/IP)            │  │
│  └──────────────┬──────────┘   └──────────┬──────────┘  │
│                 │                          │               │
│  ┌──────────────▼──────────┐   ┌──────────▼──────────┐  │
│  │  NVMe Core Driver       │   │  NIC Driver         │  │
│  │  (nvme-core.ko)         │   │  (mlx5/ixgbe)       │  │
│  └──────────────────────────┘   └─────────────────────┘  │
└───────────────────────────────────────────────────────────┘

io_uring 的作用：
  · 接收应用 I/O 请求（read/write）
  · 异步提交到 NVMe/TCP 驱动
  · 异步等待完成（CQE）
  · 支持批量提交（多个 I/O 一次提交）
```

### 5.2 使用 io_uring 访问 NVMe/TCP 设备

```c
// nvme_tcp_io_uring.c — 通过 io_uring 访问 NVMe/TCP

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <liburing.h>

#define NR_OPS 32

int main() {
    struct io_uring ring;
    io_uring_queue_init_params(NR_OPS, &ring, &(struct io_uring_params){0});

    // 打开 NVMe/TCP 设备（由内核 nvme-tcp 驱动创建）
    int fd = open("/dev/nvme0n1", O_RDWR | O_DIRECT);
    if (fd < 0) {
        perror("open /dev/nvme0n1");
        return 1;
    }

    // 对齐缓冲区
    void *buf;
    posix_memalign(&buf, 4096, 4096 * NR_OPS);

    // 批量提交读取请求
    for (int i = 0; i < NR_OPS; i++) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        io_uring_prep_read(sqe, fd, buf + i * 4096, 4096, i * 4096ULL);
        sqe->user_data = i;
    }

    // 一次性提交所有请求
    io_uring_submit(&ring);

    // 批量收割结果
    struct io_uring_cqe *cqe;
    int completed = 0;
    while (completed < NR_OPS) {
        io_uring_wait_cqe(&ring, &cqe);
        if (cqe->result < 0) {
            printf("Op %lu failed: %s\n",
                   cqe->user_data, strerror(-cqe->result));
        } else {
            printf("Op %lu: read %d bytes\n",
                   cqe->user_data, cqe->result);
        }
        io_uring_cqe_seen(&ring, cqe);
        completed++;
    }

    free(buf);
    close(fd);
    io_uring_queue_exit(&ring);
    return 0;
}
```

### 5.3 与本地 NVMe 的延迟对比

```c
// latency_compare.c — 本地 NVMe vs NVMe/TCP

#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <liburing.h>

#define ITERATIONS 10000

int64_t get_nsec() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e9 + ts.tv_nsec;
}

double benchmark_latency(int fd, int is_local) {
    char buf[4096];
    int64_t start, end;
    int64_t total = 0;

    for (int i = 0; i < ITERATIONS; i++) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
        io_uring_prep_read(sqe, fd, buf, 4096, i * 4096ULL);
        io_uring_submit(&ring);

        struct io_uring_cqe *cqe;
        start = get_nsec();
        io_uring_wait_cqe(&ring, &cqe);
        end = get_nsec();
        total += (end - start);
        io_uring_cqe_seen(&ring, cqe);
    }

    return (double)total / ITERATIONS / 1000;  // 微秒
}

int main() {
    // 本地 NVMe
    int local_fd = open("/dev/nvme0n1", O_RDONLY | O_DIRECT);
    double local_lat = benchmark_latency(local_fd, 1);

    // NVMe/TCP（网络路径）
    int tcp_fd = open("/dev/nvme0n1", O_RDONLY);  // 内核已路由
    double tcp_lat = benchmark_latency(tcp_fd, 0);

    printf("本地 NVMe 延迟: %.2f us\n", local_lat);
    printf("NVMe/TCP 延迟:  %.2f us\n", tcp_lat);
    printf("网络开销:       %.2f us\n", tcp_lat - local_lat);

    return 0;
}
```

```
预期结果：

硬件：Intel Optane P4800X + 100GbE RoCE v2
测试：4KB 随机读，10000 次迭代

单次延迟：
  本地 NVMe:           6 us
  NVMe/TCP (本地网络):  15-20 us  (+ 10-14 us 网络)
  NVMe/RDMA (RoCE v2):  8-10 us   (+ 2-4 us RDMA)
────────────────────────────────────────────
  iSCSI:              200-500 us  (太慢了)

吞吐量（iodepth=32, 16 线程）：
  本地 NVMe:          1.5M IOPS @ 7 GB/s
  NVMe/TCP (TCP):     800K IOPS @ 3 GB/s
  NVMe/RDMA (RoCE):   1.2M IOPS @ 5 GB/s
  iSCSI:              100K IOPS @ 400 MB/s

结论：
  NVMe/TCP 比 iSCSI 快 5-8x
  NVMe/RDMA 比 NVMe/TCP 再快 50%
  但都比本地 NVMe 慢（网络开销不可避免）
```

---

## 6. 性能调优

### 6.1 NVMe/TCP 调优

```bash
# NVMe/TCP 网络参数调优

# 1. 增加 TCP 缓冲区
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.core.rmem_default=16777216
sysctl -w net.core.wmem_default=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"

# 2. 启用 TCP 无延迟
sysctl -w net.ipv4.tcp_nodelay=1

# 3. 启用 BBR 拥塞控制（高带宽低延迟网络）
sysctl -w net.ipv4.tcp_congestion_control=bbr

# 4. 巨帧（Jumbo Frame）
ifconfig eth0 mtu 9000

# 5. CPU 亲和性（确保 NVMe/TCP 处理在同一核）
# 查看 NVMe/TCP 中断
grep nvme_tcp /proc/interrupts

# 6. NVMe/TCP 参数
cat /sys/module/nvme_tcp/parameters/*
# recv_queue_size:  接收队列大小
# send_queue_size: 发送队列大小
# io_queue_size:   I/O 队列大小

# 调整
echo 128 > /sys/module/nvme_tcp/parameters/io_queue_size
```

### 6.2 RDMA 调优

```bash
# RDMA (RoCE v2) 参数调优

# 1. 检查 Mellanox NIC
mlxfwmanager  # 查看固件版本
mst status   # 查看 MST 设备

# 2. 设置 QoS（可选）
mlnx_qos -a -i eth0 --prio_tc 0,1,2,3,4,5,6,7

# 3. 启用 RoCE v2
mlxconfig -d /dev/mst/mt4123_pciconf0 s roce=2

# 4. 调整 PSN 窗口（Packet Sequence Number）
# for mlx5:
echo 16384 > /sys/class/infiniband/mlx5_0/tx_queue_len

# 5. 设置 DCBX 模式
# 确保 DCB（Data Center Bridging）正确配置
dcbtool sc dev mlnx5 dcbx on

# 6. 检查 RoCE 拥塞通知
cat /sys/class/inviband/mlx5_0/ports/1/counters/extended_retrans_count
# 如果值很高 → 网络拥塞或丢包
```

### 6.3 中断与 CPU 亲和性

```bash
# NVMe-oF 中断亲和性

# 查看 NVMe 中断
cat /proc/interrupts | grep -E "nvme|mlx5"
# CPU0   CPU1   CPU2   CPU3  ...
#  123    456    789    012   nvme0q0
#  234    567    890    123   nvme0q1
#  345    678    901    234   mlx5-qp0

# 设置 NVMe 中断亲和性（固定到特定 CPU）
# 找到 nvme 中断号
IRQ_NVME=$(grep nvme0q0 /proc/interrupts | awk -F: '{print $1}')
# 设置亲和性（绑定到 CPU 0）
echo 1 > /proc/irq/$IRQ_NVME/smp_affinity

# 或者用 irqbalance（自动均衡）
systemctl enable irqbalance

# 禁用 irqbalance 对 NVMe（手动绑定）
systemctl stop irqbalance
echo 1 > /proc/irq/$IRQ_NVME/smp_affinity_list
```

---

## 7. 故障排查

### 7.1 常见问题

```bash
# ========== 问题 1: 无法发现 Target ==========

# 现象：nvme discover 失败
# Error: No discovery entries found

# 排查：
# 1. Target 是否监听？
ss -tlnp | grep 4420

# 2. 防火墙是否阻止？
iptables -L -n | grep 4420
firewall-cmd --list-ports

# 3. NQN 是否匹配？
# 检查 Target 的 subsystem NQN
cat /sys/kernel/config/nvmet/subsystems/nqn.2014-08.io.spdk:nvme0/attr_nqn

# 检查 Initiator 的 host NQN
cat /etc/nvme/hostnqn


# ========== 问题 2: 连接建立后 I/O 超时 ==========

# 现象：连接成功，但 read/write 时超时
# Error: NVMe command timeout

# 排查：
# 1. 网络连通性
ping -c 5 192.168.1.100

# 2. MTU 设置（巨帧）
ping -M do -c 3 -s 8972 192.168.1.100

# 3. 查看 NVMe 错误日志
nvme smart-log /dev/nvme0n1

# 4. 检查 NVMe/TCP 统计
cat /sys/class/nvme/nvme0/transport_stats


# ========== 问题 3: 性能低 ==========

# 现象：IOPS 远低于预期

# 排查：
# 1. 是否走网络路径？
#    本地 NVMe: /dev/nvmeXn1
#    网络 NVMe: /dev/nvmeXn1pX (可能有 nvme0c0n1 等)

# 2. 查看队列深度
cat /sys/class/nvme/nvme0/io_queue_depth

# 3. 网络延迟
ping -c 100 192.168.1.100 | tail -1

# 4. CPU 利用率（是否绑对了核？）
mpstat -P ALL 1
```

### 7.2 NVMe/TCP 统计

```bash
# 查看 NVMe/TCP 统计信息

# 设备统计
cat /sys/class/nvme/nvme0/transport_stats
# tcp_recv_pending_bindings: 0
# tcp_pending_send_bytes: 0
# tcp_pending_recv_bytes: 0
# tcp_input_queue_size: 0
# tcp_output_queue_size: 0

# 命令统计
cat /sys/class/nvme/nvme0/cid
# Controller ID

# 查看错误
cat /sys/class/nvme/nvme0/err_count
# 0  ← 无错误

# NVMe 控制器状态
cat /sys/class/nvme/nvme0/ctrl_loss_tmo
# 一直等（600 秒关机）
```

---

## 8. 小结

```
NVMe-oF 网络块设备：

为什么需要 NVMe-oF：
  · 本地 NVMe：容量有限、无法共享
  · 传统 iSCSI/NFS：协议开销大，延迟高（500us-2ms）
  · NVMe-oF：把 NVMe 高性能延伸到网络（15-20us）

传输层对比：
  RDMA (RoCE v2): ~8us 延迟，100Gbps，无需 CPU（最推荐）
  FC-NVMe:       ~10us 延迟，企业存储兼容
  NVMe/TCP:      ~15us 延迟，最灵活（RFC 8883）

NVMe-oF 命令流：
  NVMe/TCP: H2C PDU → Data In → C2H PDU
  NVMe/RDMA: RDMA Send → DMA → RDMA Write 结果

配置：
  Target: configfs 或 SPDK nvme target
  Initiator: nvme discover → nvme connect
  验证: nvme list / nvme list-subsys

io_uring 在 NVMe-oF 中：
  应用 → io_uring → NVMe/TCP Driver → Socket → NIC
  优势：批量异步 I/O、减少 syscall

性能：
  本地 NVMe:  6us, 1.5M IOPS
  NVMe/TCP:  15us, 800K IOPS
  NVMe/RDMA:  8us, 1.2M IOPS
  iSCSI:    300us, 100K IOPS

调优：
  NVMe/TCP: TCP buffer / BBR / Jumbo Frame
  RDMA: QoS / DCBX / MTU 9000
  中断亲和性绑定到专用 CPU 核
```

---

## 延伸阅读

- NVMe-oF 1.0 规范: `https://nvmexpress.org/`
- NVMe/TCP (RFC 8883): `https://datatracker.ietf.org/doc/html/rfc8883`
- NVMe/RDMA (RFC 8884): `https://datatracker.ietf.org/doc/html/rfc8884`
- Linux NVMe Target: `Documentation/nvme/nvme-target.txt`
- Linux NVMe/TCP: `drivers/nvme/target/tcp.c`
- nvme-cli: `https://github.com/linux-nvme/nvme-cli`
- RDMA (RoCE): `Documentation/infiniband/roce`
- SPDK NVMe Target: `https://spdk.io/doc/nvme.html`
- LWN: "NVMe over Fabrics": https://lwn.net/Articles/689481/
- LWN: "NVMe/TCP": https://lwn.net/Articles/825740/