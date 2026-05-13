---
title: "DPDK 深度探索 (十七)：vhost-scsi 存储虚拟化"
date: 2026-04-09
tags: [dpdk, series, vhost-scsi, virtio-scsi, storage, iSCSI, TCM, shared-memory]
description: "深入理解 vhost-scsi 存储虚拟化——VM 高性能存储访问、virtio-scsi 协议、Target Core 架构、I/O 环形缓冲区、SPDK vhost-blk"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-16. 前十六章已完成 17. **第十七章：vhost-scsi 存储虚拟化**

---

## 1. 概述：存储虚拟化背景

> [!tip] 阅读指引
> 如果你对"存储虚拟化"这个概念感到陌生，可以这样理解：
>
> **问题**：VM 里的操作系统需要"磁盘"来装系统、存数据。这个"磁盘"怎么来？
>
> **答案**：Host 机器上的一块真实硬盘（或一个文件），通过某种协议"虚拟"成 VM 能看到的磁盘设备。这个过程就是存储虚拟化。
>
> 本章讲的就是：**VM 怎么通过 virtio/vhost 协议高速访问 Host 上的存储设备**。核心思路和 ch16 vhost-user 网络加速完全一样——用**共享内存 + 环形缓冲区**替代传统的设备模拟，消除 VMEXIT 和数据拷贝开销。
>
> **前置依赖**：建议先读完第十六章（vhost-user 与 virtio 加速），理解 virtqueue、avail/used ring、共享内存映射等核心概念。本章在此基础上扩展到存储场景。

### 1.1 从网络到存储

vhost 家族不仅用于网络，还能用于存储。按后端运行位置分为两大类：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          vhost 生态                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌── 内核 vhost (ioctl /dev/vhost-*)                                      │
│  │   vhost-net      →  VM 网络 I/O (virtio-net)，内核线程处理              │
│  │                                                                         │
│  └── vhost-user 协议 (Unix Domain Socket + 共享内存)                       │
│      ├─ vhost-user-net     →  用户态网络后端 (DPDK)                        │
│      ├─ vhost-user-blk     →  用户态块设备后端 (SPDK)                      │
│      ├─ vhost-user-scsi    →  用户态 SCSI 后端 (SPDK)                      │
│      └─ vhost-user-gpu     →  用户态 GPU 后端                              │
│                                                                             │
│  关系：vhost-user 是协议名称，vhost-net/scsi/blk 是设备类型。               │
│        设备类型可以通过内核 vhost 或 vhost-user 协议运行在用户态。           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 virtio-blk vs virtio-scsi

| 特性         | virtio-blk       | virtio-scsi                          |
| ------------ | ---------------- | ------------------------------------ |
| **设备类型** | 简单块设备       | SCSI 设备                            |
| **命令**     | 仅读/写          | 完整 SCSI 命令集                     |
| **目标**     | 单一大文件/设备  | 多个 LUN，多个 Target                |
| **功能**     | 基本存储         | SCSI 特定功能（trim, report lun...） |
| **性能**     | 稍高（简单路径） | 略低（复杂协议）                     |
| **适用**     | 系统盘、数据盘   | 企业存储SAN                          |

### 1.3 存储 I/O vs 网络 I/O

| 维度         | 网络 I/O      | 存储 I/O                |
| ------------ | ------------- | ----------------------- |
| **数据单元** | Packet (可变) | Block (固定 512B/4KB)   |
| **传输模式** | 流式          | 随机访问                |
| **latency**  | μs 级         | μs 级（NVMe ~10-100μs） |
| **带宽**     | 10Gbps+       | NVMe 32Gbps+            |
| **协议栈**   | TCP/IP        | SCSI/NVMe               |

---

## 2. virtio-blk 机制

> [!note] 为什么讲 vhost-scsi 却要先讲 virtio-blk？
> 因为 virtio-blk 是最简单的 virtio 存储设备，理解它之后再看更复杂的 virtio-scsi 会轻松很多。你可以把 virtio-blk 看作"简化版 U 盘协议"——只能读写，而 virtio-scsi 是"完整版 SCSI 协议"——支持多设备、多 LUN、Task Management 等高级功能。

### 2.1 virtio-blk 结构

```c
// virtio-blk 配置
struct virtio_blk_config {
    rte_le64_t capacity;      // 容量（512字节扇区）
    rte_le32_t size_max;     // 最大段大小
    rte_le32_t seg_max;      // 最大段数
    rte_le16_t cylinders;     // 几何参数（遗留）
    rte_le8_t heads;
    rte_le8_t sectors;
    rte_le32_t blk_size;     // 块大小（通常 512）
    rte_le16_t min_io_size;  // 最小 I/O 大小
    rte_le16_t opt_io_size;  // 最佳 I/O 大小
    rte_le8_t phys_block_exp;
    rte_le8_t align_offset;
    rte_le32_t max_discard_sectors;
    rte_le32_t max_discard_seg;
    // ... 更多特性字段
};

// virtio-blk 请求头
struct virtio_blk_outhdr {
    rte_le32_t type;         // 请求类型
    rte_le32_t ioprio;       // I/O 优先级
    rte_le64_t sector;       // 起始扇区
};

// 请求类型
#define VIRTIO_BLK_T_IN           0  // 读
#define VIRTIO_BLK_T_OUT          1  // 写
#define VIRTIO_BLK_T_FLUSH         5  // 刷新
#define VIRTIO_BLK_T_DISCARD       11 // Trim/Discard
#define VIRTIO_BLK_T_WRITE_ZEROS   13 // 写零

// virtio-blk 状态
#define VIRTIO_BLK_S_OK           0
#define VIRTIO_BLK_S_IOERR        1
#define VIRTIO_BLK_S_UNSUPP       2
```

### 2.2 virtio-blk 请求格式

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    virtio-blk 请求格式                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────┐                                                      │
│  │ virtio_blk_outhdr │  16 bytes - 请求头                                │
│  │  - type          │                                                      │
│  │  - ioprio        │                                                      │
│  │  - sector        │                                                      │
│  └────────┬────────┘                                                      │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐                                                      │
│  │  Data Buffer    │  可变长度 - 读写的数据                                │
│  │  (scatter-gather) │                                                     │
│  └────────┬────────┘                                                      │
│           │                                                                │
│           ▼                                                                │
│  ┌─────────────────┐                                                      │
│  │ status          │  1 byte - 结果状态                                   │
│  └─────────────────┘                                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 virtio-blk virtqueue

```c
// virtio-blk 使用单个 virtqueue 处理所有 I/O
// 队列深度默认 128

struct virtio_blk {
    struct virtqueue *vq;         // I/O virtqueue
    struct rte_mempool *mbuf_pool;

    // actual storage backend
    struct block_device *bdev;
};

// process I/O request (simplified conceptual code)
static void
virtio_blk_handle_request(struct virtqueue *vq)
{
    while (vq->last_avail_idx != vq->avail->idx) {
        uint16_t desc_idx = vq->avail->ring[vq->last_avail_idx];

        // parse descriptor chain: outhdr + data + status
        struct virtio_blk_outhdr *hdr;
        struct iovec iov[128];
        int iovcnt = 0;
        uint32_t type, sector;
        void *status;

        parse_desc_chain(vq->desc, desc_idx, &hdr, iov, &iovcnt, &status);

        type = rte_le_to_cpu_32(hdr->type);
        sector = rte_le_to_cpu_64(hdr->sector);

        // NOTE: production vhost backends use async I/O (callback),
        // not synchronous wait_for_completion() shown here for clarity
        struct bio *bio = alloc_bio();
        bio->sector = sector;
        bio->iov = iov;
        bio->iovcnt = iovcnt;
        bio->cb = virtio_blk_complete;  // async callback

        switch (type) {
        case VIRTIO_BLK_T_IN:
            bio->cmd = BIO_READ;
            break;
        case VIRTIO_BLK_T_OUT:
            bio->cmd = BIO_WRITE;
            break;
        case VIRTIO_BLK_T_FLUSH:
            bio->cmd = BIO_FLUSH;
            break;
        }

        submit_bio(bio);  // async submit, callback fills used ring
        vq->last_avail_idx++;
    }

    // notify VM (in production: via callfd eventfd)
    eventfd_write(vq->callfd, 1);
}

// async completion callback
static void
virtio_blk_complete(struct bio *bio)
{
    struct virtqueue *vq = bio->vq;
    uint16_t desc_idx = bio->desc_idx;

    // set status byte
    *(uint8_t *)bio->status_addr = bio->error ? VIRTIO_BLK_S_IOERR
                                               : VIRTIO_BLK_S_OK;

    // put into used ring; len = total bytes written for read ops
    vq->used->ring[vq->used->idx % vq->size].id = desc_idx;
    vq->used->ring[vq->used->idx % vq->size].len =
        (bio->cmd == BIO_READ) ? bio->bytes_done : 0;
    vq->used->idx++;

    // notify VM
    eventfd_write(vq->callfd, 1);
}
```

---

## 3. virtio-scsi 机制

> [!note] virtio-scsi 解决什么问题？
> virtio-blk 虽然简单高效，但有明显局限：一个 virtio-blk 设备只能对应一块磁盘。如果 VM 需要访问多块磁盘（比如企业 SAN 场景下挂载几十个 LUN），就需要创建几十个 virtio-blk 设备，管理起来很麻烦。
>
> virtio-scsi 把整个 SCSI 协议搬进了 virtio，VM 看到的是一个 SCSI 控制器，下面可以挂多个 Target、多个 LUN。同时支持完整的 SCSI 命令集（包括 TRIM、Report LUN、Persistent Reservation 等企业级功能）。
>
> **代价**：协议更复杂，每个 I/O 请求的头部更大（35 bytes vs 16 bytes），处理路径更长。对只需要单盘的场景，virtio-blk 性能略优。

### 3.1 virtio-scsi 结构

```c
// virtio-scsi configuration (per virtio spec v1.1)
struct virtio_scsi_config {
    __le32 num_queues;       // number of request queues
    __le32 seg_max;          // max segments per request
    __le32 max_sectors;      // max sectors per request
    __le32 cmd_per_lun;      // max commands per LUN
    __le32 event_info_size;  // event info size
    __le32 sense_size;       // sense data size
    __le16 cdb_size;         // CDB size (typically 16)
    __le16 max_channel;      // max channel number
    __le16 max_target;       // max target number
    __le64 max_lun;          // max LUN number
};

// virtio-scsi command request ( Guest → Host )
// NOTE: CDB is embedded INLINE (16 bytes), not passed by address!
struct virtio_scsi_cmd_req {
    __u8 lun[8];              // 8-byte LUN address (single-level: first byte)
    __le64 tag;               // per-command tag for matching response
    __u8 task_attr;           // SIMPLE/ORDERED/HEAD/ACA
    __u8 prio;                // priority
    __u8 crn;                 // Command Reference Number
    __u8 cdb[16];             // SCSI CDB, embedded inline
};
// Total: 8 + 8 + 1 + 1 + 1 + 16 = 35 bytes

// virtio-scsi command response ( Host → Guest )
// NOTE: sense data goes into the data_in buffer of the descriptor chain,
// NOT via any address field in this struct
struct virtio_scsi_cmd_resp {
    __le32 sense_len;         // bytes of sense data written
    __le32 residual;          // residual data length
    __le16 status_qualifier;  // status qualifier
    __u8  status;             // SCSI status byte
    __u8  response;           // response code (see VIRTIO_SCSI_S_*)
};
// Total: 4 + 4 + 2 + 1 + 1 = 12 bytes

// SCSI response codes
#define VIRTIO_SCSI_S_OK                    0
#define VIRTIO_SCSI_S_OVERRUN               1
#define VIRTIO_SCSI_S_ABORTED               2
#define VIRTIO_SCSI_S_BAD_TARGET            3
#define VIRTIO_SCSI_S_RESET                 4
#define VIRTIO_SCSI_S_BUSY                  5
#define VIRTIO_SCSI_S_TRANSPORT_FAILURE     6
#define VIRTIO_SCSI_S_TARGET_FAILURE        7
#define VIRTIO_SCSI_S_NEXUS_FAILURE         8
#define VIRTIO_SCSI_S_FAILURE               9
```

### 3.2 virtio-scsi virtqueue

```c
// virtio-scsi uses THREE virtqueues:
//   1. Control Virtqueue  - management commands (reset, abort)
//   2. Event Virtqueue    - async events (hotplug, async SCSI events)
//   3. Request Virtqueue(s) - I/O commands (one per queue, can have multiple)

struct virtio_scsi {
    struct virtqueue *ctrl_vq;   // control commands
    struct virtqueue *event_vq;  // async events from target
    struct virtqueue **req_vqs;  // I/O request queues (can be multiple)
    uint16_t num_queues;
};

// descriptor chain layout for a SCSI command:
//
//   desc[0] ──► virtio_scsi_cmd_req (35 bytes, device-readable)
//   desc[1] ──► data_out buffer (WRITE direction, device-readable) [optional]
//   desc[2] ──► data_in buffer  (READ direction, device-writable)  [optional]
//   desc[3] ──► virtio_scsi_cmd_resp (12 bytes, device-writable)
//   desc[4] ──► sense data buffer (device-writable, up to sense_size) [optional]
//
// NOTE: sense data is in its own descriptor buffer, NOT at an address
//       in the response struct.

// process I/O request queue (simplified conceptual code)
static void
virtio_scsi_handle_cmd(struct virtqueue *vq, int vid)
{
    while (vq->last_avail_idx != vq->avail->idx) {
        uint16_t desc_idx = vq->avail->ring[vq->last_avail_idx & (vq->size - 1)];

        // walk the descriptor chain to find req, data_out, data_in, resp, sense
        struct virtio_scsi_cmd_req *req = NULL;
        struct virtio_scsi_cmd_resp *resp = NULL;
        void *data_out = NULL, *data_in = NULL, *sense_buf = NULL;
        uint32_t data_out_len = 0, data_in_len = 0, sense_len = 0;

        uint16_t cur = desc_idx;
        int desc_pos = 0;  // track position in chain

        while (cur != VQ_DESC_CHAIN_END) {
            struct vring_desc *d = &vq->desc[cur];
            void *addr = rte_vhost_va_from_guest_pa(vid, d->addr);

            switch (desc_pos) {
            case 0: req = (struct virtio_scsi_cmd_req *)addr; break;
            case 1:
                if (d->flags & VRING_DESC_F_WRITE) {
                    // data_in comes before resp when there's no data_out
                    data_in = addr;
                    data_in_len = d->len;
                } else {
                    data_out = addr;
                    data_out_len = d->len;
                }
                break;
            case 2:
                if (d->len == sizeof(struct virtio_scsi_cmd_resp)) {
                    resp = (struct virtio_scsi_cmd_resp *)addr;
                } else {
                    data_in = addr;
                    data_in_len = d->len;
                }
                break;
            case 3:
                if (d->len == sizeof(struct virtio_scsi_cmd_resp)) {
                    resp = (struct virtio_scsi_cmd_resp *)addr;
                } else {
                    sense_buf = addr;
                    sense_len = d->len;
                }
                break;
            case 4:
                sense_buf = addr;
                sense_len = d->len;
                break;
            }
            desc_pos++;
            cur = (d->flags & VRING_DESC_F_NEXT) ? d->next : VQ_DESC_CHAIN_END;
        }

        if (!req || !resp) {
            vq->last_avail_idx++;
            continue;
        }

        // CDB is INLINE in the request, no address translation needed
        uint8_t *cdb = req->cdb;
        uint8_t cdb_len = 16;  // always 16 bytes per virtio spec

        // parse LUN (single-level: first byte)
        uint8_t lun_id = req->lun[0];
        uint64_t tag = rte_le_to_cpu_64(req->tag);

        // determine data direction from CDB
        int is_write = (cdb[0] & 0x01) && cdb[0] != 0x28 &&
                       cdb[0] != 0x08;  // simplified check

        // execute SCSI command (async in production)
        uint8_t scsi_status = 0;
        uint32_t residual = 0;
        uint32_t sense_written = 0;

        if (is_write && data_out) {
            scsi_status = execute_scsi_write(lun_id, cdb, data_out, data_out_len);
        } else if (data_in) {
            uint32_t bytes_read = execute_scsi_read(lun_id, cdb,
                                data_in, data_in_len);
            residual = data_in_len - bytes_read;
        }

        // fill response
        memset(resp, 0, sizeof(*resp));
        resp->response = VIRTIO_SCSI_S_OK;
        resp->status = scsi_status;
        resp->residual = rte_cpu_to_le_32(residual);
        resp->sense_len = rte_cpu_to_le_32(sense_written);

        // put into used ring
        vq->used->ring[vq->used->idx % vq->size].id = desc_idx;
        vq->used->ring[vq->used->idx % vq->size].len = sizeof(*resp);
        vq->used->idx++;
        vq->last_avail_idx++;
    }

    // notify VM via callfd
    eventfd_write(vq->callfd, 1);
}
```

> [!important] CDB 内联 vs 指针传递
> 这是最容易出错的地方。virtio-scsi 的 CDB **直接内嵌在 `virtio_scsi_cmd_req` 结构体中**（16 字节），不需要通过地址间接访问。早期文档和一些实现可能使用指针方式，但 virtio v1.1 规范明确规定 CDB 是内联的。
>
> 同样，sense 数据也不是通过 `resp->sense_addr` 传递的——它在描述符链的独立 buffer 中（通常在 resp 之后）。响应结构体中只有 `sense_len` 表示写了多少 sense 数据。

---

## 4. SPDK vhost-blk

> [!note] SPDK 是什么？和 DPDK 什么关系？
> **SPDK** (Storage Performance Development Kit) 是 Intel 开源的**用户态存储框架**，和 DPDK 是兄弟项目。DPDK 负责"网卡 bypass"，SPDK 负责"存储 bypass"。
>
> SPDK 的核心思想：绕过内核文件系统（ext4/xfs）和内核块设备层，**用户态直接驱动 NVMe 硬件**，实现存储 I/O 的零拷贝、无中断、全轮询。
>
> **硬件需求**：SPDK 不需要特殊硬件。它提供多种 bdev 后端：
>
> - `malloc bdev`：纯内存盘，零硬件依赖，适合开发测试
> - `AIO bdev`：普通文件或传统硬盘，内核 AIO 路径，无特殊要求
> - `NVMe bdev`：NVMe SSD（PCIe 直连），**生产环境首选**——这才是 SPDK 性能优势所在
> - `CUSE bdev`：用户态字符设备
>
> 唯一的"软性"要求是 Linux 内核开启 IOMMU（`intel_iommu=on`）和配置大页内存，和 DPDK 一样。
>
> SPDK vhost 是 SPDK 中的 vhost-user 后端实现——VM 的 virtio-blk/scsi 请求通过 vhost-user 协议直接交给 SPDK 处理，不再经过 QEMU 的模拟层。这就是"VM 直通到 SPDK 用户态存储"的完整路径。

### 4.1 SPDK vhost 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SPDK vhost 架构                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                         QEMU                                        │  │
│  │  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐       │  │
│  │  │  VM 1        │    │   VM 2        │    │   VM 3        │       │  │
│  │  │  virtio-blk  │    │   virtio-blk  │    │   virtio-scsi │       │  │
│  │  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘       │  │
│  │          │                    │                    │               │  │
│  │          └────────────────────┼────────────────────┘               │  │
│  │                               │                                      │  │
│  └───────────────────────────────┼──────────────────────────────────────┘  │
│                                  │                                          │
│                        Unix Domain Socket                                  │
│                                  │                                          │
│  ┌───────────────────────────────┼──────────────────────────────────────┐  │
│  │                               ▼                                      │  │
│  │  ┌──────────────────────────────────────────────────────────────────┐ │  │
│  │  │                    SPDK vhost library                            │ │  │
│  │  │  ┌────────────────┐    ┌────────────────┐    ┌────────────────┐  │ │  │
│  │  │  │  vhost-blk    │    │  vhost-blk    │    │  vhost-scsi   │  │ │  │
│  │  │  │  controller   │    │  controller   │    │  controller   │  │ │  │
│  │  │  └───────┬───────┘    └───────┬───────┘    └───────┬───────┘  │ │  │
│  │  │          │                    │                    │          │ │  │
│  │  │          ▼                    ▼                    ▼          │ │  │
│  │  │  ┌────────────────────────────────────────────────────────────┐│ │  │
│  │  │  │               bdev layer (块设备抽象层)                     ││ │  │
│  │  │  └──────┬──────────────┬──────────────┬──────────────────────┘│ │  │
│  │  └─────────┼──────────────┼──────────────┼───────────────────────┘  │
│  │            │              │              │                            │
│  │            ▼              ▼              ▼                            │
│  │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐                  │
│  │  │  NVMe bdev   │ │  malloc bdev │ │  AIO bdev    │                  │
│  │  │  (PCIe)      │ │  (内存盘)     │ │  (文件/盘)   │                  │
│  │  └──────────────┘ └──────────────┘ └──────────────┘                  │
│  │                                                                   │  │
│  │                        DPDK + SPDK                                │  │
│  └───────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 SPDK vhost-blk 实现

```c
// Simplified SPDK vhost-blk internal structure (spdk/lib/vhost/vhost_blk.c)

struct spdk_vhost_blk_dev {
    struct spdk_vhost_dev     base;       // vhost device base

    struct spdk_vhost_virtqueue *bvqs;    // block virtqueue array
    uint16_t                  num_queues;

    struct spdk_bdev          *bdev;      // underlying block device
    struct spdk_bdev_desc     *bdev_desc; // bdev descriptor (opened ref)
};

// submit I/O via SPDK bdev high-level API (NOT fn_table->submit_request)
static void
vhost_blk_submit_io(struct spdk_vhost_virtqueue *bvq,
                    struct spdk_vhost_blk_task *task)
{
    struct spdk_vhost_blk_dev *ctrl = SPDK_CONTAINEROF(bvq->dev,
                                        struct spdk_vhost_blk_dev, base);
    struct spdk_io_channel *ch = bvq->iochannel;

    switch (task->req->type) {
    case VIRTIO_BLK_T_IN:
        // READ: data flows from bdev → VM (data_in)
        spdk_bdev_readv(ctrl->bdev, ch,
                        task->iov_out, task->iovcnt_out,
                        task->req->sector * 512,
                        task->iov_out_len,
                        vhost_blk_task_complete, task);
        break;

    case VIRTIO_BLK_T_OUT:
        // WRITE: data flows from VM → bdev (data_out)
        spdk_bdev_writev(ctrl->bdev, ch,
                         task->iov_in, task->iovcnt_in,
                         task->req->sector * 512,
                         task->iov_in_len,
                         vhost_blk_task_complete, task);
        break;

    case VIRTIO_BLK_T_FLUSH:
        spdk_bdev_flush(ctrl->bdev, ch, 0, 0,
                        vhost_blk_task_complete, task);
        break;

    case VIRTIO_BLK_T_DISCARD:
        spdk_bdev_unmap(ctrl->bdev, ch,
                        task->req->sector * 512,
                        task->iov_out_len,
                        vhost_blk_task_complete, task);
        break;

    case VIRTIO_BLK_T_WRITE_ZEROS:
        spdk_bdev_write_zeroes(ctrl->bdev, ch,
                               task->req->sector * 512,
                               task->iov_out_len,
                               vhost_blk_task_complete, task);
        break;
    }
}

// async I/O completion callback
static void
vhost_blk_task_complete(struct spdk_bdev_io *bdev_io, bool success, void *arg)
{
    struct spdk_vhost_blk_task *task = arg;
    struct spdk_vhost_virtqueue *bvq = task->bvq;

    spdk_bdev_free_io(bdev_io);

    // write status byte
    *task->status = success ? VIRTIO_BLK_S_OK : VIRTIO_BLK_S_IOERR;

    // put into used ring
    vhost_vq_used_ring_enqueue(bvq, task->desc_idx,
                               task->iov_out_len);

    // try to process more requests
    vhost_blk_process_vq(bvq);
}

// process virtqueue: dequeue and submit I/Os
static void
vhost_blk_process_vq(struct spdk_vhost_virtqueue *bvq)
{
    struct vhost_used_ring *used = &bvq->vring.used;
    uint16_t last_avail = bvq->last_avail_idx;

    while (last_avail != bvq->vring.avail->idx) {
        uint16_t desc_idx = bvq->vring.avail->ring[last_avail & (bvq->vring.size - 1)];

        struct spdk_vhost_blk_task *task = get_task(bvq);

        // parse virtio-blk descriptor chain: outhdr + data + status
        vhost_blk_parse_desc_chain(bvq, desc_idx, task);

        // submit async I/O
        vhost_blk_submit_io(bvq, task);

        last_avail++;
    }

    bvq->last_avail_idx = last_avail;

    // notify VM via callfd
    vhost_vq_notify(bvq);
}
```

> [!tip] SPDK bdev API vs fn_table
> SPDK 对外暴露的高层 API 是 `spdk_bdev_readv()` / `spdk_bdev_writev()` / `spdk_bdev_flush()` 等函数，内部再通过 `fn_table` 分发到底层驱动。用户代码和示例中应始终使用高层 API，`fn_table->submit_request()` 是内部实现细节。

### 4.3 创建 vhost-blk 设备

SPDK 通过 JSON-RPC 或命令行工具创建 vhost-blk 控制器，不直接暴露 C API 给用户：

```bash
# Method 1: via spdk_rpc.py (JSON-RPC)
spdk_rpc.py construct_vhost_blk_controller -b Malloc0 vhost_blk0

# Method 2: via spdk_tgt CLI
/vhost_blk_create vhost_blk0 Malloc0

# Method 3: via configuration file (spdk_vhost.conf)
[VhostBlk]
Name vhost_blk0
Dev Malloc0
```

内部 C 实现大致流程：

```c
// spdk/lib/vhost/vhost_blk.c (simplified)
int
spdk_vhost_blk_construct(const char *name, const char *bdev_name,
                         uint32_t num_queues, uint32_t queue_size)
{
    struct spdk_vhost_blk_dev *ctrl;

    // allocate controller
    ctrl = calloc(1, sizeof(*ctrl));
    if (!ctrl)
        return -ENOMEM;

    // find bdev by name
    ctrl->bdev = spdk_bdev_get_by_name(bdev_name);
    if (!ctrl->bdev) {
        SPDK_ERRLOG("bdev '%s' not found\n", bdev_name);
        free(ctrl);
        return -ENODEV;
    }

    // open bdev (exclusive for vhost-blk)
    int rc = spdk_bdev_open(ctrl->bdev, true, vhost_blk_bdev_event_cb,
                            ctrl, &ctrl->bdev_desc);
    if (rc != 0) {
        free(ctrl);
        return rc;
    }

    // register as vhost-user device
    // socket path: /var/tmp/<name> by default
    rc = spdk_vhost_dev_register(&ctrl->base, name, num_queues,
                                 queue_size, &vhost_blk_device_ops);

    return rc;
}
```

QEMU 侧连接：

```bash
qemu-system-x86_64 \
    -chardev socket,id=vhost-blk0,path=/var/tmp/vhost_blk0 \
    -device virtio-blk-pci,chardev=vhost-blk0 \
    -m 4096 -smp 4 ...
```

---

## 5. TCM (Target Core) 架构

### 5.1 TCM 概述

Linux TCM (Target Core / LIO) 是内核的 SCSI Target 框架，支持：

- iSCSI Target
- FC Target
- vhost-scsi (virtio-scsi 后端)
- TCMU (用户态后端)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            TCM (LIO) 架构                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                         用户空间                                       │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │ │
│  │  │  targetcli — LIO/TCM 的标准管理工具                              │ │ │
│  │  │  配置 LUN、Target、Portal Group、ACL 等                           │ │ │
│  │  └─────────────────────────────────────────────────────────────────┘ │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                             │                                              │
│  ┌─────────────────────────┴─────────────────────────────────────────────┐ │
│  │                      Target Core (内核模块)                            │ │
│  │                                                                       │ │
│  │  ┌────────────────────────────────────────────────────────────────┐  │ │
│  │  │  TCM Core (target_core_mod.c)                                  │  │ │
│  │  │  - ConfigFS: /sys/kernel/config/target/                        │  │ │
│  │  │  - se_device: 设备管理                                          │  │ │
│  │  │  - se_lun: LUN 管理                                            │  │ │
│  │  │  - se_portal_group: Portal Group (TPGT)                        │  │ │
│  │  │  - se_node_acl: Initiator 访问控制                               │  │ │
│  │  │  - TMR: Task Management Request (ABORT_TASK, etc.)              │  │ │
│  │  └────────────────────────────────────────────────────────────────┘  │ │
│  │                                                                       │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────┐  │ │
│  │  │  FILEIO      │  │  IBLOCK      │  │  PSCSI       │  │  TCMU     │  │ │
│  │  │  (文件后端)   │  │  (块设备后端) │  │  (物理SCSI)  │  │(用户态)  │  │ │
│  │  │              │  │  /dev/sdX    │  │  PCIe HBA   │  │          │  │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘  └──────────┘  │ │
│  │                                                                       │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  传输层 (Transport):                                                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │  iSCSI       │  │  FC          │  │  vhost-scsi  │  │  TCMU        │  │
│  │  (TCP/IP)    │  │  (Fibre Ch)  │  │  (virtio)    │  │  (user space)│  │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

  配置示例 (targetcli):
  $ targetcli
  /> cd /backstores/fileio
  /> create my_disk /path/to/disk.img 10G
  /> cd /iscsi
  /> create iqn.2024-01.com.example:storage
  /> cd iqn.2024-01.com.example:storage/tpg1/luns
  /> create /backstores/fileio/my_disk
  /> cd /vhost
  /> create naa.6001405deadbeef
```

### 5.2 vhost-scsi TCM 后端

内核 vhost-scsi (drivers/vhost/scsi.c) 作为 TCM 的传输层，将 virtio-scsi 命令转换为 TCM 的 `se_cmd` 处理：

```c
// drivers/vhost/scsi.c (simplified, kernel 6.x)

struct vhost_scsi_tpg {
    // TCM Target Portal Group
    u16 tport_tpgt;
    struct se_portal_group se_tpg;
    struct vhost_scsi_tport *tport;     // parent target port
};

// main I/O submission path
static void
vhost_scsi_handle_cmd(struct vhost_virtqueue *vq,
                      struct vhost_scsi_cmd *cmd)
{
    struct vhost_scsi_nexus *tv_nexus = cmd->tv_nexus;
    struct se_session *se_sess = tv_nexus->se_sess;
    struct virtio_scsi_cmd_req *req = &cmd->req;
    struct se_cmd *se_cmd = &cmd->se_cmd;

    // parse LUN from req->lun[0] (single-level addressing)
    struct se_lun *se_lun;
    u64 unpacked_lun;
    int ret;

    unpacked_lun = vhost_scsi_unpack_lun(req->lun, sizeof(req->lun));
    if (unpacked_lun == VHOST_SCSI_MAX_LUN) {
        /* LUN out of range */
        vhost_scsi_send_cmd_resp(cmd, VIRTIO_SCSI_S_BAD_TARGET);
        return;
    }

    // init se_cmd (TCM command structure)
    // CDB is inline in req, no address translation needed
    ret = target_init_cmd(se_cmd, se_sess, req->cdb,
                          scsi_command_size(req->cdb),
                          req->task_attr, &cmd->sense_buf,
                          VHOST_SCSI_SENSE_BUFFERSIZE,
                          DMA_NONE, 0, 0, __GFP_RECLAIM);
    if (ret < 0) {
        vhost_scsi_send_cmd_resp(cmd, VIRTIO_SCSI_S_FAILURE);
        return;
    }

    // set up data buffers from descriptor chain
    if (cmd->data_direction != DMA_NONE) {
        ret = target_alloc_sgl(se_cmd, cmd->tvc_sgl,
                               cmd->tvc_sgl_count, cmd->data_direction,
                               cmd->tvc_data_len);
        if (ret < 0)
            goto fail;
    }

    // parse CDB and dispatch to TCM engine
    ret = target_setup_cmd_from_cdb(se_cmd);
    if (ret == TCM_NO_SENSE)
        transport_generic_new_cmd(se_cmd);
    else if (ret < 0)
        goto fail;

    return;

fail:
    transport_generic_handle_tmr(se_cmd);
}
```

> [!note] 内核 API 说明
> `target_init_cmd()` → `target_setup_cmd_from_cdb()` → `transport_generic_new_cmd()` 是内核 TCM 的标准三步走。`target_init_cmd()` 初始化 `se_cmd`，`target_setup_cmd_from_cdb()` 解析 CDB 确定操作类型和数据方向，`transport_generic_new_cmd()` 将命令分发给对应的 backstore (FILEIO/IBLOCK/PSCSI) 执行。

---

## 6. iSCSI 与 vhost-scsi

### 6.1 iSCSI 协议栈

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          iSCSI 协议栈                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                         iSCSI 层                                      │ │
│  │  - SCSI Command/Response                                             │ │
│  │  - Login/Logout                                                      │ │
│  │  - NOP-In/Out                                                        │ │
│  │  - Text/RTT                                                         │ │
│  └───────────────────────────────┬───────────────────────────────────────┘ │
│                                  │                                          │
│  ┌───────────────────────────────┴───────────────────────────────────────┐ │
│  │                         TCP 层                                          │ │
│  │  - 连接管理                                                           │ │
│  │  - 流量控制                                                           │ │
│  │  - 拥塞控制                                                           │ │
│  └───────────────────────────────┬───────────────────────────────────────┘ │
│                                  │                                          │
│  ┌───────────────────────────────┴───────────────────────────────────────┐ │
│  │                         IP 层                                          │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.2 vhost-scsi vs iSCSI

| 特性       | vhost-scsi           | iSCSI        |
| ---------- | -------------------- | ------------ |
| **位置**   | VM 内部              | 网络         |
| **传输**   | 共享内存 (virtqueue) | TCP/IP 网络  |
| **延迟**   | ~1μs                 | ~100-500μs   |
| **带宽**   | 几乎无上限           | 受网络限制   |
| **兼容性** | 需要 virtio 驱动     | 标准 TCP/IP  |
| **目标**   | 本地高速存储         | 远程存储访问 |

---

## 7. 性能对比

### 7.1 存储虚拟化性能对比

> [!note] 数据来源
> 以下数据为典型数量级参考，基于 SPDK/DPDK 官方 benchmark 和社区公开测试结果。
> 实际性能取决于硬件（NVMe 型号、CPU、内存）、配置（队列深度、numa 亲和性）等因素。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│           存储虚拟化性能对比 (4KB 随机读, 典型量级)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  IOPS (K)                                                                  │
│  │                                                                        │
│  1000 ┤                                                                  ***│
│       │                                                            ***     │
│  800  ┤                                                      ***           │
│       │                                                ***                  │
│  600  ┤                                            ***                      │
│       │                                        ***                          │
│  400  ┤                                    ***                              │
│       │                               ***                                  │
│  200  ┤                          ***                                        │
│       │                     ***                                             │
│    0  ┤*******************                                                   │
│       └────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──   │
│           │    │    │    │    │    │    │    │    │    │    │    │    │     │
│          物理  KVM   SPDK  QEMU   iSCSI  NFS   物理  KVM   SPDK  QEMU     │
│          NVMe 直通  vhost  virtio  (10G) v3   NVMe 直通  vhost  virtio     │
│          PCIe        -blk  -blk                               -blk  -blk   │
│                                                                             │
│  延迟 (μs)                                                                 │
│  │                                                                        │
│   10 ┤                                                                  ╱╲   │
│       │                                                                 ╱  ╲  │
│    8 ┤                                                              ╱╲       │
│       │                                                          ╱╲    ╲     │
│    6 ┤                                                       ╱╲   ╲        │
│       │                                                   ╱╲   ╲            │
│    4 ┤                                                ╱╲   ╲               │
│       │                                            ╱╲   ╲                   │
│    2 ┤                                        ╱╲   ╲                           │
│       │                                   ╱╲   ╲                            │
│    0 ┤******************************╱╲*****╲                                   │
│       └────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬──   │
│          物理  KVM   SPDK  QEMU   iSCSI  NFS   物理  KVM   SPDK  QEMU     │
│          NVMe 直通  vhost  virtio  (10G) v3   NVMe 直通  vhost  virtio     │
│          PCIe        -blk  -blk                               -blk  -blk   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
│                                                                             │
│  方案          │ 后端          │ 数据路径          │ 关键瓶颈                │
│  ──────────────┼───────────────┼───────────────────┼─────────────────────── │
│  物理直通       │ SR-IOV VF     │ VM 直接访问硬件    │ 无（性能最高）         │
│  SPDK vhost-blk│ SPDK 用户态   │ 共享内存 + 轮询    │ CPU 开销              │
│  QEMU virtio-blk│ QEMU 内核    │ 共享内存 + 中断    │ VMEXIT / 中断开销      │
│  iSCSI (10G)   │ 网络          │ TCP/IP 协议栈     │ 网络延迟 + 协议开销    │
│  NFS v3        │ 网络          │ RPC over UDP/TCP │ 网络延迟 + RPC 开销    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 优化建议

| 优化项       | virtio-blk  | virtio-scsi  |
| ------------ | ----------- | ------------ |
| **队列深度** | 128-256     | 每个 LUN 128 |
| **多队列**   | 启用多队列  | 启用多队列   |
| **块大小**   | 4KB 对齐    | 4KB 对齐     |
| **写缓存**   | 启用 (BBWC) | 启用         |
| **I/O 合并** | 启用        | 启用         |

---

## 8. 小结

本章核心要点：

1. **vhost 存储生态**：vhost 设备类型（net/blk/scsi）可通过内核 vhost 或 vhost-user 协议运行。vhost-user 是用户态后端协议，DPDK/SPDK 通过它实现高性能存储虚拟化。

2. **virtio-blk**：简单块设备协议，单 virtqueue，outhdr + data + status 描述符链结构。`VIRTIO_BLK_T_FLUSH = 5`（不是 2）。生产后端使用异步 I/O 回调，不阻塞等待。

3. **virtio-scsi 请求结构**：`cmd_req` 中 CDB 是**内联 16 字节**（不是地址指针），LUN 是 8 字节，还有 tag/crn 等字段。响应结构字段顺序为 `sense_len → residual → status_qualifier → status → response`。

4. **virtio-scsi sense 数据**：通过描述符链中的独立 buffer 传递，不在响应结构体中放地址字段。

5. **virtio-scsi 三队列模型**：控制队列（管理命令）、事件队列（异步通知）、请求队列（I/O 命令，可多个）。

6. **SPDK vhost**：用户态高性能存储虚拟化，使用 `spdk_bdev_readv()` / `spdk_bdev_writev()` 等高层 bdev API，不直接调用 `fn_table`。通过 JSON-RPC 或 `spdk_tgt` CLI 创建控制器。

7. **TCM (LIO)**：Linux 内核 SCSI Target 框架，标准管理工具是 `targetcli`。vhost-scsi 作为 TCM 的传输层，通过 `target_init_cmd()` → `target_setup_cmd_from_cdb()` → `transport_generic_new_cmd()` 三步处理命令。

8. **vhost-scsi vs iSCSI**：vhost-scsi 通过共享内存实现超低延迟 (~1μs)，iSCSI 通过网络实现远程访问 (~100-500μs)。

9. **性能排序**：物理 NVMe > KVM 直通 > vhost-blk > virtio-blk > iSCSI (10G) > NFS v3。

10. **优化方向**：队列深度、块大小对齐、写缓存策略、I/O 合并。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch18-ivshmem|第十八章]]将讲解 IVSHMEM VM 间共享内存——无hypervisor参与的 VM 间高速通信。

---

> [!tip] 参考文献
>
> - "virtio-blk 规范", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html#x1-141005
> - "virtio-scsi 规范", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html#x1-151007
> - Intel, "SPDK vhost", https://spdk.io/doc/vhost.html
> - "Linux TCM", https://www.kernel.org/doc/html/latest/target/tcmu-design.html
