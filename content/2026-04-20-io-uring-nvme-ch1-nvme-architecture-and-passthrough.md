---
title: io_uring × NVMe 深度探索 Ch1：NVMe 架构与 io_uring passthrough
date: 2026-04-20 09:00:00
tags:
  [
    io_uring,
    NVMe,
    Storage,
    PCIe,
    Passthrough,
    Kernel Bypass,
    High Performance,
    Admin Commands,
    IO Commands,
    Block Layer,
  ]
description: 深入讲解 NVMe 硬件架构：PCIe 寄存器模型、Submission Queue / Completion Queue、命令格式，以及 io_uring passthrough 如何绕过文件系统直接操作 NVMe。
---

# io_uring × NVMe 深度探索 Ch1：NVMe 架构与 io_uring passthrough

## 1. 为什么 NVMe 是 io_uring 的最佳拍档

```
传统存储 I/O 路径（4-8 层开销）：
┌──────────────────────────────────────────────────────┐
│  应用                                                  │
│   → write()/read()                                  │
│  VFS                                                  │
│   → ext4 / xfs                                       │
│  Page Cache（可能合并/阻塞）                          │
│  Block Layer                                          │
│   → elevator（调度算法：cfq/deadline/mq-deadline）   │
│   → bio merge                                        │
│  SCSI Layer（转换协议）                               │
│   → SATA / SAS 控制器                                │
│  硬件                                                  │
│   → SATA SSD（6 Gbps）                               │
└──────────────────────────────────────────────────────┘
   延迟：50-200us

io_uring + NVMe 路径（2-3 层开销）：
┌──────────────────────────────────────────────────────┐
│  应用                                                  │
│   → io_uring SQE 提交                                 │
│  Block Layer（NVMe 驱动）                            │
│   → 直接构造 NVMe SQ/CQ 描述符                       │
│  PCIe DMA                                             │
│   → 直接内存访问                                      │
│  NVMe SSD                                             │
└──────────────────────────────────────────────────────┘
   延迟：2-15us（10x 提升）

关键差异：
  1. 无文件系统层（可以直接发 NVMe 命令）
  2. 无 Page Cache（O_DIRECT）
  3. 无 SCSI 转换层（NVMe 直出）
  4. 无 SATA/SAS 协议开销（PCIe 直连）
  5. 多核并行：每个 CPU 独立 SQ/CQ pair
```

---

## 2. NVMe 硬件架构

### 2.1 PCIe 物理层

```
NVMe SSD 通过 PCIe 连接：

┌─────────────┐         ┌─────────────┐
│   CPU       │         │   NVMe SSD  │
│   ┌───────┐ │         │  ┌────────┐  │
│   │  PCIe │────────────│  │  PCIe  │  │
│   │ Root  │ │   x4     │  │   PHY  │  │
│   │ Port  │ │   Gen4   │  │        │  │
│   └───────┘ │   16GT/s │  └────────┘  │
│             │         │      │        │
│   DMA       │         │  ┌───▼───┐  │
│   Engine    │◄─────────│  │  NAND  │  │
│             │  DMA R/W │  │  Flash │  │
│             │         │  └────────┘  │
└─────────────┘         └─────────────┘

带宽对比：
  PCIe Gen3 x4:  ~3.9 GB/s (32 Gbps)
  PCIe Gen4 x4:  ~7.9 GB/s (64 Gbps)
  PCIe Gen5 x4:  ~15.8 GB/s (128 Gbps)

NVMe SSD 实际吞吐（PCIe Gen4 x4）：
  顺序读:  ~7 GB/s
  顺序写:  ~6.5 GB/s
  随机读:  ~1.5M IOPS
  随机写:  ~1M IOPS
```

### 2.2 NVMe 寄存器模型

```
NVMe 控制器通过 PCIe BAR 空间暴露寄存器：

┌────────────────────────────────────┐
│  BAR0 / BAR1 (64-bit BAR)         │
├────────────────────────────────────┤
│  Capability (0x00)                │
│    · CAP.NVMQS (Queue数)         │
│    · CAP.MQES (最大队列深度)     │
│    · CAP.AMS (仲裁机制)           │
│    · CAP.CSS (Controller Suffix)│
│  Version (0x08)                   │
│    · NVMF 规范版本                │
│  Interrupt Mask Set (0x1C)       │
│  Interrupt Mask Clear (0x20)     │
│  Configuration (0x24)             │
│    · CC.EN (Enable)               │
│    · CC.IOSQES (SQ Entry 大小)   │
│    · CC.IOCQES (CQ Entry 大小)   │
│    · CC.CSS (Command Sets)       │
│  Configuration (0x24)             │
│  Status (0x28)                    │
│    · CSTS.RDY (Ready)             │
│    · CSTS.CFS (Controller Fatal) │
│    · CSTS.SHST (Shutdown)         │
│  NVM Subsystem Reset (0x30)       │
│  Admin Queue Attributes (0x34)    │
│  ──────── Admin SQ Base (0x38) ── │
│  Admin SQ Size (0x3C)             │
│  Admin CQ Base (0x40)             │
│  Admin CQ Size (0x44)             │
│  ──────── I/O SQ Base (0x1000+) ─│
│  I/O SQ1 Base                     │
│  I/O SQ1 Size                     │
│  I/O CQ1 Base                     │
│  I/O CQ1 Size                     │
│  ... (最多 64K 个 I/O 队列)       │
└────────────────────────────────────┘

关键寄存器：

CAP (Controller Capability):
  .mqes   = 最大队列条目数（最多 64K）
  .ams    = 仲裁机制（WRR/RR）
  .cqr    = 提交队列_requires_cq（通常 1）
  .css    = 命令集支持（NVM 命令集=1）

CC (Controller Configuration):
  .en     = 控制器使能
  .css    = 命令集选择（00b=Admin, 01b=IO）
  .shn    = 关机通知
  .iosqes = SQ Entry size（6=64字节）
  .iocqes = CQ Entry size（4=16字节）

CSTS (Controller Status):
  .rdy    = 控制器就绪
  .cfs    = 控制器故障
  .shst   = 关机状态
```

### 2.3 NVMe 命令格式（64 字节 SQ Entry）

```c
// NVMe I/O 命令结构（64 字节）
struct nvme_io_command {
    __u8  opcode;           // [0] 操作码
    __u8  flags;            // [1] FUSE / PSDT
    __u16 ctrl;             // [2-3] 命令标识
    __u32 nsid;             // [4-7] Namespace ID
    __u64 rsvd2;           // [8-15] reserved
    __u64 metadata;         // [16-23] 元数据指针
    __u64 prp1;             // [24-31] 物理寄存器页 1
    __u64 prp2;             // [32-39] 物理寄存器页 2
    __u64 cdw10;            // [40-47] 命令特定 DW10
    __u64 cdw11;            // [48-55] 命令特定 DW11
    __u64 cdw12;            // [56-63] 命令特定 DW12
    __u64 cdw13;            // [64-71] 命令特定 DW13
    __u64 cdw14;            // [72-79] 命令特定 DW14
    __u64 cdw15;            // [80-87] 命令特定 DW15
};

// NVMe Admin 命令（同样的 64 字节结构）
// opcode 范围：0x00-0x0F

// 常用 Admin 命令操作码：
NVME_ADMIN_DELETE_SQ      0x00
NVME_ADMIN_CREATE_SQ      0x01
NVME_ADMIN_GET_LOG_PAGE   0x02
NVME_ADMIN_DELETE_CQ      0x04
NVME_ADMIN_CREATE_CQ      0x05
NVME_ADMIN_IDENTIFY       0x06
NVME_ADMIN_ABORT          0x08
NVME_ADMIN_SET_FEATURES   0x09
NVME_ADMIN_GET_FEATURES   0x0A
NVME_ADMIN_FW COMMIT      0x10
NVME_ADMIN_FW IMG_DL      0x11
NVME_ADMIN_FORMAT_NVM     0x80
NVME_ADMIN_SECURITY_SEND  0x81
NVME_ADMIN_SECURITY_RECV  0x82

// 常用 I/O 命令操作码（NVM 命令集）：
NVME_NVM_CMD_READ         0x02  // 读
NVME_NVM_CMD_WRITE        0x01  // 写
NVME_NVM_CMD_FLUSH        0x00  // 刷新（落盘）
NVME_NVM_CMD_DISCARD      0x04  // 丢弃块
NVME_NVM_CMD_WRITE_ZEROS  0x08  // 写零

// NVMe 读取示例：
// opcode = 0x02 (NVM_CMD_READ)
// cdw10[15:00] = 起始 LBA (32-bit)
// cdw10[31:16] = LBA count (要读多少块)
// prp1 = 数据缓冲区物理地址（页对齐）
// prp2 = 第二页（如果缓冲区跨页）

// NVMe 写入示例：
// opcode = 0x01 (NVM_CMD_WRITE)
// cdw10[15:00] = 起始 LBA
// cdw10[31:16] = LBA count
// prp1 = 数据缓冲区物理地址
```

### 2.4 Submission Queue 与 Completion Queue

```
NVMe 的队列模型：

┌─────────────────────────────────────────────────────────────┐
│                     NVMe Controller                         │
│                                                             │
│    Submission Queue (SQ)        Completion Queue (CQ)      │
│    ┌──────────────────┐         ┌──────────────────┐       │
│    │ SQE[0]  (64B)   │────────►│ CQE[0]  (16B)   │       │
│    │ SQE[1]  (64B)   │         │ CQE[1]  (16B)   │◄───   │
│    │ SQE[2]  (64B)   │         │ CQE[2]  (16B)   │       │
│    │ ...             │         │ ...             │       │
│    │ SQE[n]  (64B)   │         │ CQE[n]  (16B)   │       │
│    └──────────────────┘         └──────────────────┘       │
│            ▲                              │                 │
│            │    Host DMA                  │                 │
└────────────┼──────────────────────────────┼─────────────────┘
             │                              │
┌────────────┼──────────────────────────────┼─────────────────┐
│   Host CPU  │                              │                 │
│            │                              │                 │
│    SQ Tail │◄────────────────────────────│    CQ Head      │
│            │  (写 SQ Tail，更新 doorbell)  │  (更新 doorbell) │
│            │                              │                 │
│    SQ Head │                              │    CQ Tail      │
│    (驱动读取)│                             │  (驱动读取)     │
└────────────┴──────────────────────────────┴─────────────────┘

CQE (Completion Queue Entry) 结构（16 字节）：
struct nvme_completion {
    __u32 result;       // [0-3]   结果（命令特定）
    __u32 rsvd;         // [4-7]   reserved
    __u16 sq_head;      // [8-9]   关联 SQ 的 head（用于检测完成）
    __u16 sq_id;       // [10-11] SQ 标识
    __u16 cid;         // [12-13] Command ID
    __u16 status;      // [14-15] 状态（P鹭 / SCT）
};

状态字段：
  status.P   = Phase Tag（判断新/旧完成）
  status.SCT = Status Code Type（0=Generic, 1=Command Specific）
  status.SC  = Status Code（具体错误码）

多队列机制：
  NVMe 最多支持 64K 个 I/O SQ 和 64K 个 I/O CQ
  每个 CPU 核心可以独立拥有 1-N 个 SQ/CQ pair
  → 完全无锁并行！
```

### 2.5 PRP（Physical Region Page）寻址

```
NVMe 不支持 SGL（ Scatter-Gather List）默认使用 PRP：

PRP 是什么：
  NVMe 通过 PRP（Physical Region Page）描述数据缓冲区
  每个 PRP entry 是 64-bit 物理地址（4KB 对齐）

单页缓冲区（prp1 指向数据）：
┌─────────────────────────────────────┐
│ prp1 = 缓冲区物理地址（4K 对齐）   │
│ prp2 = 0（保留）                   │
└─────────────────────────────────────┘

两页缓冲区（prp1 + prp2）：
┌─────────────────────────────────────┐
│ prp1 = 第一页物理地址（4K 对齐）   │
│ prp2 = 第二页物理地址（4K 对齐）   │
└─────────────────────────────────────┘

跨多页缓冲区（PRP List）：
┌─────────────────────────────────────┐
│ prp1 = PRP List 地址（页对齐）     │
│ prp2 = 0                            │
│                                     │
│  PRP List（内存中）：               │
│    entry[0] = page 1 phys addr      │
│    entry[1] = page 2 phys addr      │
│    entry[2] = page 3 phys addr      │
│    ...                              │
└─────────────────────────────────────┘

注意：
  NVMe 1.0+ 支持 SGL（Scatter-Gather List）
  SGL 更灵活（支持非对齐缓冲区）
  但大多数 NVMe SSD 推荐使用 PRP（兼容性更好）
```

---

## 3. io_uring passthrough 原理

### 3.1 什么是 passthrough

```
Passthrough = 绕过操作系统通用层，直接向硬件发送命令

传统路径（5层）：
  应用 → VFS → 文件系统 → Block Layer → NVMe 驱动 → 硬件

Passthrough 路径（2层）：
  应用 → io_uring → NVMe 驱动 → 硬件

io_uring passthrough：
  使用 IORING_OP_URING_CMD 操作码
  SQE 中携带完整的 NVMe 命令（64字节）
  内核 NVMe 驱动执行命令
  CQE 返回 NVMe 完成状态

优势：
  - 无文件系统（直接块设备访问）
  - 无 Page Cache（O_DIRECT 级别）
  - 无 bio merge/split（直接 NVMe 命令）
  - 可自定义 NVMe 命令（admin/IO passthrough）
```

### 3.2 IORING_OP_URING_CMD（5.6+）

```c
// 5.6+ 支持的用户命令操作码

struct io_uring_sqe {
    __u8    opcode;         // = IORING_OP_URING_CMD
    __u8    flags;          // IOSQE_*
    __u16   ioprio;
    __s32   fd;             // NVMe 块设备 fd
    __u64   off;            // 命令特定偏移（unused for NVMe）
    __u64   addr;           // 用户缓冲区地址（nvme_uring_cmd*）
    __u32   len;            // 缓冲区长度
    union { __u32 rw_flags; ... };
    __u64   user_data;
    union { ... };
    // 5.19+ 扩展
    struct {
        __u16 buf_index;    // fixed buffer index
        __u16 buf_group;   // buffer group
    } h2c;
    __u8    buf_index_high;
    __u8    pad[5];
};

// NVMe passthrough 命令结构
struct nvme_uring_cmd {
    __u8    opcode;         // NVMe 命令操作码
    __u8    flags;         // NVMe 命令 flags
    __u16   control;       // 命令控制
    __u32   nsid;          // Namespace ID
    __u64   metadata;       // 元数据地址
    __u64   addr;          // 数据缓冲区地址
    __u64   metadata_len;  // 元数据长度
    __u32   data_len;      // 数据长度
    __u32   cdw2;          // 命令特定 DW2
    __u32   cdw3;          // 命令特定 DW3
    __u32   cdw10;         // ...
    __u32   cdw11;
    __u32   cdw12;
    __u32   cdw13;
    __u32   cdw14;
    __u32   cdw15;
    __u64   user_data;     // 透传到 CQE
    __u64   result;        // 输出：NVMe 命令 result
};
```

### 3.3 Admin Passthrough 示例

```c
// nvme_admin_identify.c — 通过 io_uring 发送 Admin 命令

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <linux/nvme_ioctl.h>  // nvme_admin_passthru
#include <liburing.h>

#define DEV_PATH "/dev/nvme0n1"

int main() {
    struct io_uring ring;
    io_uring_queue_init(32, &ring, 0);

    int fd = open(DEV_PATH, O_RDONLY | O_DIRECT);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    // Identify Controller（查询控制器能力）
    struct nvme_uring_cmd cmd = {0};
    struct nvme_controller_data ctrl_data = {0};

    cmd.opcode = 0x06;  // NVME_ADMIN_IDENTIFY
    cmd.addr = (unsigned long)&ctrl_data;
    cmd.data_len = sizeof(ctrl_data);
    cmd.cdw10 = 0;  // CNS = 0（Controller）
    cmd.cdw11 = 0;

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    memset(sqe, 0, sizeof(*sqe));
    sqe->opcode = IORING_OP_URING_CMD;
    sqe->fd = fd;
    sqe->addr = (unsigned long)&cmd;
    sqe->len = sizeof(cmd);
    sqe->user_data = IDENTIFY_TAG;

    io_uring_submit(&ring);

    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);

    if (cqe->result == 0) {
        printf("Identify 成功\n");
        printf("  VID: 0x%04x\n", ctrl_data.vid);
        printf("  SSVID: 0x%04x\n", ctrl_data.ssvid);
        printf("  Model: %.40s\n", ctrl_data.model);
        printf("  Serial: %.20s\n", ctrl_data.sn);
        printf("  Max Queue Depth: %d\n", ctrl_data.mqes + 1);
        printf("  Version: %d.%d.%d\n",
               ctrl_data.ver >> 16,
               (ctrl_data.ver >> 8) & 0xff,
               ctrl_data.ver & 0xff);
    } else {
        printf("Identify 失败: %d\n", cqe->result);
    }

    io_uring_cqe_seen(&ring, cqe);
    io_uring_queue_exit(&ring);
    close(fd);
    return 0;
}
```

### 3.4 I/O Passthrough 示例

```c
// nvme_io_passthrough.c — NVMe 读写命令

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <liburing.h>

#define DEV_PATH "/dev/nvme0n1"
#define BLK_SIZE 4096
#define LBA_COUNT 8

int main() {
    struct io_uring ring;
    io_uring_queue_init(64, &ring, 0);

    int fd = open(DEV_PATH, O_RDWR | O_DIRECT);
    if (fd < 0) {
        perror("open");
        return 1;
    }

    // 对齐缓冲区
    void *buf;
    posix_memalign(&buf, 4096, BLK_SIZE * LBA_COUNT);
    memset(buf, 'X', BLK_SIZE * LBA_COUNT);

    // NVMe 写入命令
    struct nvme_uring_cmd write_cmd = {0};
    write_cmd.opcode = 0x01;  // NVME_NVM_CMD_WRITE
    write_cmd.addr = (unsigned long)buf;
    write_cmd.data_len = BLK_SIZE * LBA_COUNT;
    write_cmd.nsid = 1;  // Namespace 1
    write_cmd.cdw10 = 0;  // cdw10[15:0] = start LBA
    write_cmd.cdw10 = LBA_COUNT << 16;  // cdw10[31:16] = LBA count
    write_cmd.user_data = WRITE_TAG;

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    sqe->opcode = IORING_OP_URING_CMD;
    sqe->fd = fd;
    sqe->addr = (unsigned long)&write_cmd;
    sqe->len = sizeof(write_cmd);
    io_uring_submit(&ring);

    struct io_uring_cqe *cqe;
    io_uring_wait_cqe(&ring, &cqe);
    printf("WRITE: result=%d\n", cqe->result);
    io_uring_cqe_seen(&ring, cqe);

    // 清空缓冲区
    memset(buf, 0, BLK_SIZE * LBA_COUNT);

    // NVMe 读取命令
    struct nvme_uring_cmd read_cmd = {0};
    read_cmd.opcode = 0x02;  // NVME_NVM_CMD_READ
    read_cmd.addr = (unsigned long)buf;
    read_cmd.data_len = BLK_SIZE * LBA_COUNT;
    read_cmd.nsid = 1;
    read_cmd.cdw10 = 0;  // start LBA = 0
    read_cmd.cdw10 = LBA_COUNT << 16;  // LBA count
    read_cmd.user_data = READ_TAG;

    sqe = io_uring_get_sqe(&ring);
    sqe->opcode = IORING_OP_URING_CMD;
    sqe->fd = fd;
    sqe->addr = (unsigned long)&read_cmd;
    sqe->len = sizeof(read_cmd);
    io_uring_submit(&ring);

    io_uring_wait_cqe(&ring, &cqe);
    printf("READ: result=%d\n", cqe->result);
    if (cqe->result == 0) {
        // 验证数据
        char *p = buf;
        printf("前 16 字节: ");
        for (int i = 0; i < 16; i++) printf("%c", p[i]);
        printf("\n");
    }
    io_uring_cqe_seen(&ring, cqe);

    free(buf);
    io_uring_queue_exit(&ring);
    close(fd);
    return 0;
}
```

---

## 4. NVMe 多队列与命名空间

### 4.1 多队列初始化流程

```
NVMe 控制器初始化（从驱动视角）：

1. 读取 PCI BAR0 寄存器
2. 读取 CAP（能力寄存器）
   → 支持多少队列？MQES = 最多队列深度
   → 支持哪些命令集？CSS
3. 启用控制器（CC.EN = 1）
4. 等待控制器就绪（CSTS.RDY = 1）
5. 创建 Admin SQ/CQ（队列 0）
6. 创建 I/O SQ/CQ pair（队列 1-N）
   → 每个 CPU 核心一个 I/O 队列
7. 配置中断（MSI-X）
8. Identify 命令（查询控制器和命名空间信息）
9. 开始处理 I/O

多队列分配策略：
  · 每个 CPU 核心一个 SQ/CQ pair
  · 线程亲和性绑定到特定核心
  · 该核心的 I/O 直接提交到自己的队列
  · 完全无锁，零竞争
```

### 4.2 命名空间（Namespace）

```c
// NVMe 命名空间管理

// 一个 NVMe 控制器可以管理多个命名空间（类似 LUN）
// 每个命名空间是一个独立的逻辑块设备

// Identify Namespace（NVM 命令集， CNS=0x02）
struct nvme_ns_data {
    __u64     nsze;              // 命名空间总大小（LBA count）
    __u64     ncap;              // 可用空间
    __u64     nuse;              // 已用空间
    __u8      nsfeat;            // 特性
    __u8      nslba;             // LBA 大小（2的幂）
    __u8      flbas;             // 元数据配置
    __u8      mc;                // 元数据能力
    __u8      dpc;               // 端到端数据保护能力
    __u8      dps;               // 端到端数据保护类型
    __u8      nsact;             // 命名空间状态
    __u8      nawat;             // 写原子性
    __u8      nvmcap[16];        // NVMe 特有容量
    __u8      rsvd90[88];
    __u8      eui64[8];          // IEEE EUI-64
    __u8      nguid[16];        // NVMe Global Unique ID
    __u8      lbafmt[128];      // LBA 格式
    // ...
};

// 查询所有命名空间
void list_namespaces(int fd) {
    struct nvme_uring_cmd cmd = {0};
    struct nvme_ns_list ns_list = {0};

    cmd.opcode = 0x06;  // ADMIN_IDENTIFY
    cmd.addr = (unsigned long)&ns_list;
    cmd.data_len = sizeof(ns_list);
    cmd.cdw10 = 0;  // CNS = 0（Namespace list）
    cmd.cdw11 = 0;

    // 提交并获取结果...

    // ns_list.nn  = 命名空间数量
    // ns_list.ns[] = 命名空间 ID 列表
    for (int i = 0; i < 1024; i++) {
        if (ns_list.ns[i] == 0) break;
        printf("Namespace %d\n", ns_list.ns[i]);
    }
}

// 选择特定命名空间
int ns_id = 1;  // 默认 NS1
ioctl(fd, NVME_IOCTL_ID, ns_id);  // 设置默认命名空间
```

### 4.3 LBA 与数据保护

```c
// NVMe LBA（Logical Block Address）寻址

// NVMe 使用 LBA 代替传统的扇区号
// 每个 LBA = N bytes（N = lba_size，常见 512 或 4096）

// 读取 LBA 0-99（共 100 个 LBA）
__u64 start_lba = 0;
__u32 lba_count = 100;

cmd.cdw10 = start_lba & 0xFFFFFFFF;          // cdw10[31:0]
cmd.cdw10 |= (lba_count & 0xFFFF) << 16;      // cdw10[47:32] = count
cmd.cdw11 = start_lba >> 32;                  // cdw11[31:0] = start_lba high

// NVMe 数据保护（DIX - DIF/DIX）
// NVMe 1.3+ 支持端到端数据保护

// protection info 类型：
//  Type 1: LBA + App Tag（无 metadata）
//  Type 2: LBA + App Tag + Ref Tag（2个保护字段）
//  Type 3: 只用 Ref Tag

struct pi_tuple {
    __u16 app_tag;    // 应用标签
    __u32 ref_tag;    // 引用标签（基于 LBA）
    __u8  app_mask;  // 应用掩码
};
// 每个 sector 末尾附加 8-16 字节 PI
```

---

## 5. 性能对比：buffered vs O_DIRECT vs passthrough

### 5.1 测试方法

```bash
#!/bin/bash
# benchmark.sh — 三种模式的性能对比

DEV="/dev/nvme0n1"
MOUNT="/mnt/nvme"
SIZE="1G"
BS="4k"

echo "=== 测试配置 ==="
echo "设备: $DEV"
echo "块大小: $BS"
echo "文件大小: $SIZE"
echo ""

# 1. buffered I/O（默认）
echo ">>> Buffered I/O (fsync)"
fio --name=buffered --filename=$MOUNT/testfile \
    --size=$SIZE --bs=$BS --ioengine=psync --iodepth=1 \
    --rw=randread --runtime=10 --time_based \
    --direct=0 --fsync=1 2>&1 | grep -E "IOPS|lat"

# 2. O_DIRECT + libaio
echo ">>> O_DIRECT + io_uring"
fio --name=direct_uring --filename=$DEV \
    --size=$SIZE --bs=$BS --ioengine=io_uring \
    --iodepth=32 --rw=randread --runtime=10 --time_based \
    --direct=1 2>&1 | grep -E "IOPS|lat"

# 3. NVMe passthrough（需要内核支持）
# NVMe 命令直接发送到硬件，跳过 block layer
```

### 5.2 预期结果

```
测试环境：Intel Optane P4800X (375GB), PCIe Gen3 x4
         CPU: Intel Xeon 2.4GHz, 16 cores

单线程随机读（iodepth=1）：
                              延迟        IOPS
─────────────────────────────────────────────────
read() + page cache           8us        120K    （命中 cache）
read() + O_DIRECT             12us        80K     （内核路径）
io_uring + O_DIRECT           8us        125K    （省 syscall）
io_uring + NVMe passthrough   6us        165K    （再省 block layer）
─────────────────────────────────────────────────
libaio + O_DIRECT             15us        65K    （较差）
SPDK（对比基线）              3us        330K    （用户态王者）

多线程随机读（iodepth=32, 16线程）：
                              延迟        IOPS
─────────────────────────────────────────────────
io_uring + O_DIRECT          180us       1.2M
io_uring + NVMe passthrough  160us       1.5M
SPDK                          120us       2.0M
─────────────────────────────────────────────────

分析：
  1. page cache 命中时最快（但不可靠）
  2. NVMe passthrough 比 O_DIRECT 快约 20-30%
     （省了 bio 构造、block layer 处理）
  3. SPDK 最快（完全用户态，无内核介入）
  4. 差距在多线程时更明显（锁竞争）
```

### 5.3 延迟分布

```
延迟分布对比（p50 / p99 / p999）：

io_uring + O_DIRECT：
  p50:     8us
  p99:    45us
  p999:  180us
  max:   500us

io_uring + NVMe passthrough：
  p50:     6us      ← 下降 25%
  p99:    35us      ← 下降 22%
  p999:  140us      ← 下降 22%
  max:   400us

SPDK：
  p50:     3us
  p99:    18us
  p999:   60us
  max:   150us

关键观察：
  p999 和 max 差距大 → 说明有尾延迟（tail latency）
  可能原因：
    - GC（垃圾回收，SSD 内部）
    - 带宽限制（PCIe 饱和）
    - 队列饱和（深度不够）
```

---

## 6. 深入：NVMe Admin 命令实战

### 6.1 获取日志页

```c
// nvme_get_log_page.c — 读取 NVMe SMART / 错误日志

#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <liburing.h>
#include <linux/nvme_ioctl.h>

// NVMe 日志页 ID
#define NVME_LOG_ERROR       0x01  // 错误信息
#define NVME_LOG_HEALTH_INFO 0x02  // SMART / 健康信息
#define NVME_LOG_FW_SLOT     0x03  // 固件槽信息

struct nvme_uring_cmd get_log_page(int fd, __u8 log_page, __u32 nsid) {
    struct nvme_uring_cmd cmd = {0};
    struct nvme_log_page log = {0};

    cmd.opcode = 0x02;  // GET_LOG_PAGE
    cmd.nsid = nsid;
    cmd.addr = (unsigned long)&log;
    cmd.data_len = sizeof(log);
    cmd.cdw10 = log_page | (0x3F << 16);  // NUMD=0（1个DWORD）
    // cdw10[15:0] = Log Page ID
    // cdw10[31:16] = NUMD（要读的 DWORD 数 - 1）

    return cmd;
}

// SMART 健康信息（128 字节）
struct nvme_health_log {
    __u8  critical_warning;
    __u32 temperature;           // Kelvin
    __u64 available_spare;
    __u64 available_spare_threshold;
    __u64 percentage_used;
    __u64 data_units_read[2];
    __u64 data_units_written[2];
    __u64 host_reads[2];
    __u64 host_writes[2];
    __u64 controller_busy_time[2];
    __u64 power_cycles[2];
    __u64 power_on_hours[2];
    __u64 unsafe_shutdowns[2];
    __u64 media_errors[2];
    __u64 error_log_entries[2];
    // ...
};

void print_health(int fd) {
    struct nvme_health_log health = {0};
    struct nvme_uring_cmd cmd = {0};

    cmd.opcode = 0x02;  // GET_LOG_PAGE
    cmd.nsid = 1;
    cmd.addr = (unsigned long)&health;
    cmd.data_len = sizeof(health);
    cmd.cdw10 = NVME_LOG_HEALTH_INFO | (sizeof(health)/4 - 1) << 16;

    // 提交命令...

    if (health.critical_warning & 0x01)
        printf("⚠️  可用 spare 低于阈值\n");
    if (health.critical_warning & 0x02)
        printf("⚠️  温度超过阈值\n");
    if (health.critical_warning & 0x04)
        printf("⚠️  可靠性下降\n");

    printf("温度: %u K (%f C)\n", health.temperature,
           (double)health.temperature - 273.15);
    printf("可用 spare: %lu%%\n", health.available_spare);
    printf("已用 spare: %lu%%\n", health.percentage_used);
}
```

### 6.2 固件管理

```c
// nvme_firmware.c — 固件下载和激活

// Step 1: 下载固件镜像（固件到控制器）
struct nvme_uring_cmd fw_download(int fd, void *fw_data, __u32 size) {
    struct nvme_uring_cmd cmd = {0};

    cmd.opcode = 0x11;  // FW_IMAGE_DL
    cmd.addr = (unsigned long)fw_data;
    cmd.data_len = size;
    cmd.cdw10 = (size / 4) - 1;  // NUMD（按 DWORD 计数）
    cmd.cdw11 = 0x01;  // 固件 slot？取决于实现

    return cmd;
}

// Step 2: 激活固件
struct nvme_uring_cmd fw_commit(int fd, __u8 slot, __u8 action) {
    struct nvme_uring_cmd cmd = {0};

    cmd.opcode = 0x10;  // FW_COMMIT
    cmd.cdw10 = slot | (action << 3);
    // action:
    //   0 = 下载完成，跳过激活
    //   1 = 下载完成后激活（下次启动生效）
    //   2 = 下载完成后立即激活
    //   3 = 下载完成后立即激活（重置控制器）

    return cmd;
}

// Step 3: 读取固件槽信息
struct nvme_uring_cmd fw_slot_log(int fd) {
    struct nvme_uring_cmd cmd = {0};
    struct nvme_fw_slot_info slots = {0};

    cmd.opcode = 0x02;  // GET_LOG_PAGE
    cmd.addr = (unsigned long)&slots;
    cmd.data_len = sizeof(slots);
    cmd.cdw10 = NVME_LOG_FW_SLOT | (sizeof(slots)/4 - 1) << 16;

    return cmd;
}
```

---

## 7. 小结

```
NVMe 架构与 io_uring passthrough：

NVMe 硬件架构：
  PCIe x4 Gen4: ~8 GB/s 带宽
  寄存器 BAR0: Capability / Config / Status
  多队列：最多 64K SQ/CQ pair
  PRP 寻址：物理页对齐的 64-bit 地址
  64 字节 SQE + 16 字节 CQE

NVMe 命令类型：
  Admin（0x00-0x0F）：Identify / SMART / 固件 / 特性
  I/O（NVM 命令集）：Read / Write / Flush / Write Zeroes
  命令格式：opcode + nsid + prp1/prp2 + cdw10-15

io_uring passthrough（5.6+）：
  IORING_OP_URING_CMD
  SQE.addr = nvme_uring_cmd 结构
  绕过 VFS/文件系统/Page Cache/Block Layer
  直接发送 NVMe 命令到驱动

优势：
  延迟：6-12us（vs 12-20us O_DIRECT）
  IOPS：+20-30%（省 block layer）
  可自定义 NVMe Admin 命令

性能对比：
  buffered (cache hit): 8us, 120K IOPS
  O_DIRECT: 12us, 80K IOPS
  io_uring + O_DIRECT: 8us, 125K IOPS
  io_uring + passthrough: 6us, 165K IOPS
  SPDK: 3us, 330K IOPS

最佳实践：
  O_DIRECT + io_uring：对大多数应用足够
  passthrough：需要自定义 NVMe 命令时
  SPDK：极致性能（微秒级延迟需求）
```

---

## 延伸阅读

- NVMe 1.4b 规范: `https://nvmexpress.org/`
- Linux NVMe 驱动: `drivers/nvme/host/core.c`
- io_uring CMD: `fs/io_uring/rw.c` (io_uring_cmd 处理)
- `linux/nvme_ioctl.h` — NVMe ioctl 定义
- fio io_uring engine: `engines/io_uring.c`
- LWN: "NVMe over Fabrics": https://lwn.net/Articles/689481/
- LWN: "io_uring and NVMe": https://lwn.net/Articles/849787/
- SPDK: `https://spdk.io/`
