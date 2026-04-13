---
title: "DPDK 深度探索 (十七)：vhost-scsi 存储虚拟化"
date: 2026-04-09
tags: [dpdk, series, vhost-scsi, virtio-scsi, storage, iSCSI, TCM, shared-memory]
description: "深入理解 vhost-scsi 存储虚拟化——VM 高性能存储访问、virtio-scsi 协议、Target Core 架构、I/O 环形缓冲区、SPDK vhost-blk"
---

> [!info] DPDK 深度探索系列
> 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-16. 前十六章已完成
> 17. **第十七章：vhost-scsi 存储虚拟化**

---

## 1. 概述：存储虚拟化背景

### 1.1 从网络到存储

vhost 家族不仅用于网络，还能用于存储：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          vhost 生态                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  vhost-net      →  VM 网络 I/O (virtio-net)                               │
│  vhost-scsi     →  VM 存储 I/O (virtio-scsi)                              │
│  vhost-blk      →  VM 块设备 I/O (virtio-blk)                            │
│  vhost-user     →  通用用户态后端 (Cuse, vhost-user-gpu)                   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 virtio-blk vs virtio-scsi

| 特性 | virtio-blk | virtio-scsi |
|------|------------|-------------|
| **设备类型** | 简单块设备 | SCSI 设备 |
| **命令** | 仅读/写 | 完整 SCSI 命令集 |
| **目标** | 单一大文件/设备 | 多个 LUN，多个 Target |
| **功能** | 基本存储 | SCSI 特定功能（trim, report lun...） |
| **性能** | 稍高（简单路径） | 略低（复杂协议） |
| **适用** | 系统盘、数据盘 | 企业存储SAN |

### 1.3 存储 I/O vs 网络 I/O

| 维度 | 网络 I/O | 存储 I/O |
|------|----------|----------|
| **数据单元** | Packet (可变) | Block (固定 512B/4KB) |
| **传输模式** | 流式 | 随机访问 |
| **latency** | μs 级 | μs-ns 级（SSD） |
| **带宽** | 10Gbps+ | NVMe 32Gbps+ |
| **协议栈** | TCP/IP | SCSI/NVMe |

---

## 2. virtio-blk 机制

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
#define VIRTIO_BLK_T_FLUSH         2  // 刷新
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

    // 实际存储后端
    struct block_device *bdev;
};

// 处理 I/O 请求
static void
virtio_blk_handle_request(struct virtqueue *vq)
{
    while (vq->last_avail_idx != vq->avail->idx) {
        uint16_t desc_idx = vq->avail->ring[vq->last_avail_idx];

        // 解析描述符链
        struct virtio_blk_outhdr *hdr;
        struct iovec iov[128];
        int iovcnt = 0;
        uint32_t type, sector;
        void *status;

        parse_desc_chain(vq->desc, desc_idx, &hdr, iov, &iovcnt, &status);

        type = rte_le_to_cpu_32(hdr->type);
        sector = rte_le_to_cpu_64(hdr->sector);

        struct bio *bio = alloc_bio();
        bio->sector = sector;
        bio->iov = iov;
        bio->iovcnt = iovcnt;

        switch (type) {
        case VIRTIO_BLK_T_IN:
            bio->cmd = BIO_READ;
            submit_bio(bio);
            break;

        case VIRTIO_BLK_T_OUT:
            bio->cmd = BIO_WRITE;
            submit_bio(bio);
            break;

        case VIRTIO_BLK_T_FLUSH:
            bio->cmd = BIO_FLUSH;
            submit_bio(bio);
            break;
        }

        // 等待完成
        wait_for_completion(&bio->comp);

        // 设置状态
        *(uint8_t *)status = VIRTIO_BLK_S_OK;

        // 放入 used 环
        vq->used->ring[vq->used->idx].id = desc_idx;
        vq->used->ring[vq->used->idx].len = 1;  // status byte
        vq->used->idx++;

        vq->last_avail_idx++;
    }

    // 通知 VM
    eventfd_write(vq->callfd, 1);
}
```

---

## 3. virtio-scsi 机制

### 3.1 virtio-scsi 结构

```c
// virtio-scsi 配置
struct virtio_scsi_config {
    rte_le32_t num_queues;       // 队列数
    rte_le32_t seg_max;          // 最大段数
    rte_le32_t max_sectors;      // 最大扇区数
    rte_le32_t cmd_per_lun;      // 每 LUN 命令数
    rte_le32_t event_info_size;  // 事件信息大小
    rte_le32_t sense_size;       // sense 数据大小
    rte_le64_t cdb_size;         // CDB 大小
    rte_le32_t max_channel;
    rte_le16_t max_target;
    rte_le16_t max_lun;
};

// virtio-scsi 请求头 (SCSI CDB)
struct virtio_scsi_cmd_req {
    uint8_t lun[3];              // LUN 地址
    uint8_t task_attr;           // Task attributes
    rte_le32_t prio;             // 优先级
    rte_le64_t cdb_addr;         // CDB 地址（VM 内存）
    rte_le32_t cdb_len;          // CDB 长度
};

// virtio-scsi 响应
struct virtio_scsi_cmd_resp {
    uint8_t response;            // 响应状态
    uint8_t status;             // SCSI 状态
    rte_le32_t residual;         // 剩余长度
    rte_le16_t status_qualifier; // 状态限定符
    rte_le32_t sense_len;        // sense 数据长度
    rte_le64_t sense_addr;       // sense 数据地址
};

// SCSI 响应
#define VIRTIO_SCSI_S_OK         0
#define VIRTIO_SCSI_S_OVERRUN    1
#define VIRTIO_SCSI_S_ABORTED    2
#define VIRTIO_SCSI_S_BAD_TARGET 3
#define VIRTIO_SCSI_S_RESET      4
#define VIRTIO_SCSI_S_BUSY       5
#define VIRTIO_SCSI_S_TRANSPORT  6
#define VIRTIO_SCSI_S_TARGET_FAILURE 7
#define VIRTIO_SCSI_S_NEXUS_FAILURE   8
#define VIRTIO_SCSI_S_FAILURE    9
```

### 3.2 virtio-scsi virtqueue

```c
// virtio-scsi 使用三个 virtqueue
// - 控制队列 (Control Virtqueue)
// - 事件队列 (Event Virtqueue)
// - 请求队列 (Request Virtqueue)

struct virtio_scsi {
    struct virtqueue *ctrl_vq;   // 控制命令
    struct virtqueue *event_vq;  // 异步事件
    struct virtqueue *req_vq;    // I/O 请求
};

// 请求队列处理
static void
virtio_scsi_handle_cmd(struct virtqueue *vq)
{
    while (vq->last_avail_idx != vq->avail->idx) {
        uint16_t desc_idx = vq->avail->ring[vq->last_avail_idx];

        // 解析请求
        struct virtio_scsi_cmd_req *req;
        struct iovec iov_in[16], iov_out[16];
        int iov_in_cnt, iov_out_cnt;

        parse_scsicmd_desc_chain(vq->desc, desc_idx,
                                   &req, iov_in, &iov_in_cnt,
                                   iov_out, &iov_out_cnt);

        // 获取 CDB
        void *cdb = vhost_gpa_to_hva(ctx, rte_le_to_cpu_64(req->cdb_addr));
        uint8_t cdb_len = rte_le_to_cpu_32(req->cdb_len);

        // 解析 LUN
        uint32_t lun = scsi_lun_to_u32(req->lun);

        // 执行 SCSI 命令
        struct scsi_sense sense;
        uint8_t status = execute_scsi_cmd(lun, cdb, cdb_len,
                                            iov_in, iov_in_cnt,
                                            iov_out, iov_out_cnt,
                                            &sense);

        // 填充响应
        struct virtio_scsi_cmd_resp *resp = get_resp_buffer(vq, desc_idx);
        resp->response = VIRTIO_SCSI_S_OK;
        resp->status = status;
        resp->sense_len = sense.len;
        resp->sense_addr = sense.addr;

        // 放入 used 环
        vq->used->ring[vq->used->idx].id = desc_idx;
        vq->used->ring[vq->used->idx].len = sizeof(*resp);
        vq->used->idx++;
        vq->last_avail_idx++;
    }

    eventfd_write(vq->callfd, 1);
}
```

---

## 4. SPDK vhost-blk

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
│  │  │  │  vhost-blk    │    │  vhost-scsi   │    │  vhost-blk    │  │ │  │
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
// spdk/lib/vhost/vhost_blk.c

struct spdk_vhost_blk_ctrl {
    struct spdk_vhost_ctrl base;     // 基类

    struct spdk_vhost_vq *bvqs;      // block virtqueue 数组
    uint16_t num_queues;

    struct spdk_bdev *bdev;          // 底层块设备
    struct spdk_bdev_desc *bdev_desc;
    struct spdk_bdev_fn_table *fn_table;
};

// 提交 I/O
static void
vhost_blk_submit_bio(struct spdk_vhost_vq *bvq,
                     struct spdk_vhost_blk_cmd *cmd)
{
    struct spdk_vhost_blk_ctrl *ctrl = bvq->ctrl;
    struct spdk_io_channel *ch = spdk_vhost_vq_get_channel(bvq);

    struct spdk_bdev *bdev = ctrl->bdev;

    switch (cmd->req.type) {
    case VIRTIO_BLK_T_IN:
        cmd->iov_out = &cmd->iovs[0];
        cmd->iovcnt_out = cmd->req.seg_cnt;
        cmd->bio = bdev->fn_table->submit_request(ch,
                bdev->ctxt,
                &cmd->bs_buf,
                SPDK_BDEV_IO_READ);
        break;

    case VIRTIO_BLK_T_OUT:
        cmd->iov_in = &cmd->iovs[0];
        cmd->iovcnt_in = cmd->req.seg_cnt;
        cmd->bio = bdev->fn_table->submit_request(ch,
                bdev->ctxt,
                &cmd->bs_buf,
                SPDK_BDEV_IO_WRITE);
        break;

    case VIRTIO_BLK_T_FLUSH:
        cmd->bio = bdev->fn_table->submit_request(ch,
                bdev->ctxt,
                &cmd->bs_buf,
                SPDK_BDEV_IO_FLUSH);
        break;

    case VIRTIO_BLK_T_DISCARD:
        cmd->bio = bdev->fn_table->submit_request(ch,
                bdev->ctxt,
                &cmd->bs_buf,
                SPDK_BDEV_IO_UNMAP);
        break;

    case VIRTIO_BLK_T_WRITE_ZEROS:
        cmd->bio = bdev->fn_table->submit_request(ch,
                bdev->ctxt,
                &cmd->bs_buf,
                SPDK_BDEV_IO_WRITE_ZEROES);
        break;
    }
}

// 完成 I/O
static void
vhost_blk_complete_bio(struct spdk_vhost_blk_cmd *cmd,
                        int status)
{
    struct spdk_vhost_vq *bvq = cmd->bvq;

    // 写入状态
    cmd->resp.status = status ? VIRTIO_BLK_S_IOERR : VIRTIO_BLK_S_OK;

    // 放入 used 环
    spdk_vhost_vq_ring_used_add(bvq, cmd->desc_idx, 1);

    // 尝试处理更多请求
    vhost_blk_process_vq(bvq);
}

// 处理 virtqueue
static void
vhost_blk_process_vq(struct spdk_vhost_vq *bvq)
{
    struct spdk_vhost_blk_ctrl *ctrl = bvq->ctrl;
    uint16_t last_avail = bvq->last_avail_idx;

    while (last_avail != bvq->avail->idx) {
        // 获取命令描述符
        struct spdk_vhost_blk_cmd *cmd = get_cmd(bvq, last_avail);

        // 解析请求
        vhost_blk_parse_req(cmd, bvq->desc, cmd->desc_idx);

        // 提交 I/O
        vhost_blk_submit_bio(bvq, cmd);

        last_avail++;
    }

    bvq->last_avail_idx = last_avail;

    // 通知 VM
    spdk_vhost_vq_notify(bvq);
}
```

### 4.3 创建 vhost-blk 设备

```c
// spdk/app/vhostctl/vhostctl.c

// 创建 vhost-blk 设备
int
create_vhost_blk_controller(const char *name, const char *bdev_name)
{
    struct spdk_vhost_blk_ctrl *ctrl;

    // 分配控制器
    ctrl = calloc(1, sizeof(*ctrl));
    if (!ctrl)
        return -ENOMEM;

    // 查找 bdev
    ctrl->bdev = spdk_bdev_get_by_name(bdev_name);
    if (!ctrl->bdev) {
        free(ctrl);
        return -ENODEV;
    }

    // 打开 bdev
    spdk_bdev_open(ctrl->bdev, true, NULL, NULL, &ctrl->bdev_desc);

    // 初始化 virtqueue
    ctrl->num_queues = 1;  // virtio-blk 通常单队列
    ctrl->bvqs = calloc(ctrl->num_queues, sizeof(struct spdk_vhost_vq));

    // 注册为 vhost-user 设备
    spdk_vhost_user_register(name,
                             &vhost_blk_ops,
                             &ctrl->base,
                             SPDK_VHOST_USER_SOCKET_PATH,
                             ctrl->num_queues);

    return 0;
}
```

---

## 5. TCM (Target Core) 架构

### 5.1 TCM 概述

Linux TCM (Target Core) 是内核的 SCSI Target 框架，支持：
- iSCSI Target
- FC Target
- vhost-scsi (virtio-scsi 后端)

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            TCM 架构                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐ │
│  │                         用户空间                                       │ │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                 │ │
│  │  │  tgtadm    │  │  LIOctl     │  │  targetctl  │                 │ │
│  │  │  (旧)       │  │  (LIO)      │  │  (vhost)    │                 │ │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                 │ │
│  └─────────┼────────────────┼────────────────┼──────────────────────────┘ │
│            │                │                │                            │
│            └────────────────┴────────────────┘                            │
│                             │                                              │
│  ┌─────────────────────────┴─────────────────────────────────────────────┐ │
│  │                      Target Core (内核模块)                            │ │
│  │                                                                       │ │
│  │  ┌────────────────────────────────────────────────────────────────┐  │ │
│  │  │  TCM Core                                                     │  │ │
│  │  │  - lun_mgr (LUN 管理)                                         │  │ │
│  │  │  - tmr (Task Management Request)                              │  │ │
│  │  │  - transport (传输层)                                          │  │ │
│  │  └────────────────────────────────────────────────────────────────┘  │ │
│  │                                                                       │ │
│  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │ │
│  │  │  FILEIO      │  │  IBLOCK      │  │  PSCSI       │              │ │
│  │  │  (文件后端)   │  │  (块设备后端) │  │  (物理SCSI)  │              │ │
│  │  └──────────────┘  └──────────────┘  └──────────────┘              │ │
│  │                                                                       │ │
│  └───────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 vhost-scsi TCM 后端

```c
// drivers/target/vhost/vhost_scsi.c

struct vhost_scsi_tpg {
    // TCM Target Portal Group
    int tport_tpgt;
    struct se_portal_group *se_tpg;

    // TCM Target
    struct se_wwn *se_wwn;
};

struct vhost_scsi_nexus {
    // TCM Node Nexus
    struct se_session *se_sess;
};

static void
vhost_scsi_handle_cmd(struct vhost_scsi_tpg *tpg,
                      struct vhost_scsi_cmd *cmd,
                      struct virtio_scsi_cmd_req *req)
{
    // 解析 LUN
    struct se_lun *lun = target_lun_lookup(&tpg->se_tpg, req->lun);

    // 获取 CDB
    void *cdb = vhost_scsi_lu_to_cp_addr(cmd->tpg, lun,
                                          req->cdb_addr, req->cdb_len);

    // 构建 TCM se_cmd
    struct se_cmd *se_cmd = &cmd->se_cmd;

    target_init_cmd(se_cmd, lun->lun_sep, se_sess,
                    cdb, req->task_attr, 0, 0, DMA_NONE);

    // 添加数据段
    if (req->data_dir != DMA_NONE) {
        struct scatterlist *sg;
        int sg_cnt;

        vhost_scsi_map_sgl(cmd, req, &sg, &sg_cnt);
        target_add_cmd_data_segments(se_cmd, sg, sg_cnt);
    }

    // 分发到 TCM
    target_dispatch_cmd(se_cmd);
}
```

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

| 特性 | vhost-scsi | iSCSI |
|------|------------|-------|
| **位置** | VM 内部 | 网络 |
| **传输** | 共享内存 (virtqueue) | TCP/IP 网络 |
| **延迟** | ~1μs | ~100-500μs |
| **带宽** | 几乎无上限 | 受网络限制 |
| **兼容性** | 需要 virtio 驱动 | 标准 TCP/IP |
| **目标** | 本地高速存储 | 远程存储访问 |

---

## 7. 性能对比

### 7.1 存储虚拟化性能对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    存储虚拟化性能对比 (4KB 随机读)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  IOPS (K)                                                                  │
│  │                                                                        │
│  1000 ┤                                                                  ***
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
│          物理  KVM   vhost  virtio   iSCSI  NFS   物理  KVM   vhost  virtio  │
│          NVMe 直通  -blk   -blk    (10G)  v3                              NVMe │
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
│          物理  KVM   vhost  virtio   iSCSI  NFS   物理  KVM   vhost  virtio  │
│          NVMe 直通  -blk   -blk    (10G)  v3                              NVMe │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 优化建议

| 优化项 | virtio-blk | virtio-scsi |
|--------|------------|-------------|
| **队列深度** | 128-256 | 每个 LUN 128 |
| **多队列** | 启用多队列 | 启用多队列 |
| **块大小** | 4KB 对齐 | 4KB 对齐 |
| **写缓存** | 启用 (BBWC) | 启用 |
| **I/O 合并** | 启用 | 启用 |

---

## 8. 小结

本章核心要点：

1. **vhost 存储生态**：vhost-net（网络）、vhost-blk（块设备）、vhost-scsi（SCSI）构成完整的 VM 虚拟化存储方案。

2. **virtio-blk**：简单块设备协议，单 virtqueue，outhdr + data + status 结构，读/写/刷新/trim/write_zeros 命令。

3. **virtio-scsi**：完整 SCSI 命令集，三 virtqueue（控制/事件/请求），支持多 LUN、多 Target、Task Management。

4. **SPDK vhost**：用户态实现的高性能存储虚拟化，bdev 抽象层支持 NVMe/AIO/malloc 等后端，零拷贝数据路径。

5. **TCM (Target Core)**：Linux 内核 SCSI Target 框架，支持 FILEIO/IBLOCK/PSCSI 后端，提供 LUN 管理和 TMR。

6. **vhost-scsi vs iSCSI**：vhost-scsi 通过共享内存实现超低延迟 (~1μs)，iSCSI 通过网络实现远程访问 (~100-500μs)。

7. **性能排序**：物理 NVMe > KVM 直通 > vhost-blk > virtio-blk > iSCSI (10G) > NFS v3。

8. **优化方向**：队列深度、块大小对齐、写缓存策略、I/O 合并。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch18-ivshmem|第十八章]]将讲解 IVSHMEM VM 间共享内存——无hypervisor参与的 VM 间高速通信。

---

> [!tip] 参考文献
> - "virtio-blk 规范", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html#x1-141005
> - "virtio-scsi 规范", https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html#x1-151007
> - Intel, "SPDK vhost", https://spdk.io/doc/vhost.html
> - "Linux TCM", https://www.kernel.org/doc/html/latest/target/tcmu-design.html
