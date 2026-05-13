---
title: io_uring × NVMe 深度探索 Ch4：SPDK 用户态 NVMe 框架
date: 2026-04-22 09:00:00
tags:
  [
    io_uring,
    NVMe,
    SPDK,
    Userspace,
    Poll Mode,
    PMD,
    FIO,
    Block Device,
    iSCSI,
    NVMf,
    Blobstore,
    Vhost,
    RDMA,
    DMA,
  ]
description: 深入讲解 SPDK 架构：用户态 NVMe 驱动、poll mode、bdev 抽象层、blobstore、vhost-blk，以及 SPDK 与 io_uring 的融合点。
---

# io_uring × NVMe 深度探索 Ch4：SPDK 用户态 NVMe 框架

## 1. 为什么需要用户态 NVMe

### 1.1 内核 NVMe 的开销

```
内核 NVMe 驱动的延迟来源：

┌─────────────────────────────────────────────────────────────┐
│  应用 I/O 路径（内核 NVMe）                              │
│                                                              │
│  应用          系统调用              NVMe Driver           │
│    │               │                     │                  │
│    ▼               ▼                     ▼                  │
│  ┌────┐  ────►  ┌───────┐  ────►  ┌─────────────┐        │
│  │buf │         │syscall│         │ bio → sgl   │        │
│  └────┘         │ overhead         │ irq handle  │        │
│                  │ (100-500ns)      │ (1-5us)     │        │
│                  └─────────────────┘                 │
│                          │                              │
│  ┌───────────────────────────────────────────────┐      │
│  │  PCIe DMA（CPU 不参与）                      │      │
│  │  ~100ns (RDMA) / ~1us (PIO)                 │      │
│  └───────────────────────────────────────────────┘      │
│                          │                              │
│                          ▼                              │
│                    ┌──────────┐                        │
│                    │ NVMe SSD │                        │
│                    └──────────┘                        │
└─────────────────────────────────────────────────────────────┘

主要开销：
  1. 系统调用：read/write = ~200ns（io_uring 消除了这个）
  2. 中断处理：中断 → CPU 调度 → 上下文恢复 = ~1-5us
  3. 锁竞争：多核共享 submit/complete queue
  4. 内存拷贝：某些路径需要拷贝

中断处理的延迟：
  NVMe 命令完成 ──► INTx/MSI-X 中断 ──► CPU 中断向量
       │                                     │
       │                              ┌──────▼──────┐
       │                              │ 中断上下文   │
       │                              │ 恢复耗时     │
       │                              └─────────────┘
       │
  如果用轮询（poll mode）：
       ▼
  命令完成 ──► CPU 主动查询 ──► 直接返回结果
  延迟降低 ~1-5us（消除中断）
```

### 1.2 SPDK 解决方案

```
SPDK = Storage Performance Development Kit

核心设计原则：
  1. 用户态驱动：绕过内核，直接访问 PCIe 设备
  2. Poll Mode：轮询代替中断，消除中断延迟
  3. 无锁设计：每个 CPU 核独立队列
  4. 零拷贝：DMA 直接到应用缓冲区

```

┌─────────────────────────────────────────────────────────────────┐
│ SPDK 架构 │
├─────────────────────────────────────────────────────────────────┤
│ │
│ ┌───────────────────────────────────────────────────────────┐ │
│ │ 应用层 │ │
│ │ ┌────────────┐ ┌────────────┐ ┌────────────┐ │ │
│ │ │ Blobstore │ │ vhost-blk │ │ NVMe-oF │ │ │
│ │ │ (KV/FS) │ │ (virtio) │ │ Target │ │ │
│ │ └─────┬──────┘ └─────┬──────┘ └─────┬──────┘ │ │
│ └────────┼───────────────┼───────────────┼────────────────┘ │
│ │ │ │ │
│ ┌────────▼───────────────▼───────────────▼────────────────┐ │
│ │ bdev 抽象层 │ │
│ │ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │ │
│ │ │ NVMe bdev│ │ malloc │ │ AIO bdev │ │ Ceph │ │ │
│ │ │ (用户态) │ │ bdev │ │ │ │ bdev │ │ │
│ │ └────┬────┘ └─────────┘ └─────────┘ └─────────┘ │ │
│ └────────┼─────────────────────────────────────────────────┘ │
│ │ │
│ ┌────────▼─────────────────────────────────────────────────┐ │
│ │ NVMe 控制器驱动（用户态） │ │
│ │ ┌──────────────────────────────────────────────────────┐ │ │
│ │ │ PCIe BAR 映射 → 寄存器访问 │ │ │
│ │ │ SQ / CQ 轮询 → 零中断 │ │ │
│ │ │ DMA 引擎 → 用户缓冲区直接映射 │ │ │
│ │ │ SGL / PRP 构造 → scatter-gather list │ │ │
│ │ └──────────────────────────────────────────────────────┘ │ │
│ └───────────────────────────────────────────────────────────┘ │
│ │ │
│ ┌────────▼────────┐ │
│ │ PCIe 总线 │ ← 直接内存访问，无内核介入 │
│ └────────┬────────┘ │
│ │ │
└───────────▼─────────────────────────────────────────────────────┘

```

---

## 2. SPDK 核心组件

### 2.1 组件概览

```

SPDK 核心组件：

┌─────────────────────────────────────────────────────────────────┐
│ 应用层 │
├─────────────────────────────────────────────────────────────────┤
│ app/ — 初始化、epoll/shutdown │
│ blobstore/ — SPDK 的 KV/文件系统 │
│ bdev/ — 块设备抽象层 │
│ env/ — 内存/DMA/RPC 初始化 │
│ ftl/ — Flash Translation Layer（nova） │
│ nvmf/ — NVMe over Fabrics target │
│ scsi/ — SCSI 目标适配层 │
│ vhost/ — vhost-user virtio 实现 │
│ include/spdk/ — 公共头文件 │
│ include/spdk/\*.h — API 定义 │
└─────────────────────────────────────────────────────────────────┘

bdev 抽象层（块设备抽象）：
作用：统一不同存储后端（NVMe/内存/文件/AIO/Ceph/RBD）
优势：上层应用只需调用 bdev 接口，无需关心底层设备

Blobstore：
SPDK 内置的 KV 存储 + 文件系统
基于 bdev，支持事务、快照、克隆
用于需要"文件系统"语义的场景（如数据库）

NVMe-oF Target：
用户态 NVMe target
比内核 nvmet 性能更高（poll mode）
支持 RDMA/TCP 传输

````

### 2.2 环境初始化

```c
// spdk_nvme_example.c — SPDK NVMe 基本使用

#include <spdk/stdinc.h>
#include <spdk/nvme.h>
#include <spdk/env.h>

// NVMe 控制器发现回调
static void
probe_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
         struct spdk_nvme_ctrlr **ctrlr)
{
    printf("发现 NVMe 控制器: %s\n", trid->traddr);
}

// 初始化完成回调
static void
attach_cb(void *cb_ctx, const struct spdk_nvme_transport_id *trid,
          struct spdk_nvme_ctrlr *ctrlr, struct spdk_nvme_ctrlr_opts *opts)
{
    printf("NVMe 控制器已连接: %s\n", spdk_nvme_ctrlr_get_name(ctrlr));
}

// NVMe 轮询线程（SPDK 的核心）
static void
nvme_poll(void *arg)
{
    struct spdk_nvme_ctrlr *ctrlr = arg;

    while (1) {
        // 轮询 NVMe 完成队列（替代中断）
        spdk_nvme_ctrlr_process_admin_completions(ctrlr);

        // 轮询所有 I/O 完成队列
        struct spdk_nvme_qpair *qpair;
        TAILQ_FOREACH(qpair, &ctrlr->nvme_qpairs, tailq) {
            spdk_nvme_qpair_process_completions(qpair, 0);
        }
    }
}

int main(int argc, char **argv)
{
    // Step 1: 初始化 SPDK 环境
    struct spdk_env_opts opts;
    spdk_env_opts_init(&opts);

    opts.name = "nvme_example";
    opts.shm_id = 0;                  // 共享内存 ID（多进程用）
    opts.core_mask = "0x1";          // 使用的 CPU 核（核 0）

    spdk_env_init(&opts);

    // Step 2: 初始化 NVMe 驱动
    if (spdk_nvme_driver_init("nvme", NULL, NULL, NULL) < 0) {
        fprintf(stderr, "NVMe 驱动初始化失败\n");
        return 1;
    }

    // Step 3: 发现并连接 NVMe 设备
    struct spdk_nvme_transport_id trid;
    memset(&trid, 0, sizeof(trid));
    trid.trtype = SPDK_NVME_TRANSPORT_PCIE;
    strncpy(trid.traddr, "0000:01:00.0", sizeof(trid.traddr));

    struct spdk_nvme_ctrlr *ctrlr;
    int rc = spdk_nvme_ctrlr_connect(&trid, &attach_cb, &ctrlr);
    if (rc < 0) {
        fprintf(stderr, "连接 NVMe 失败: %s\n", spdk_strerror(-rc));
        return 1;
    }

    // Step 4: 获取命名空间
    struct spdk_nvme_ns *ns = spdk_nvme_ctrlr_get_ns(ctrlr, 1);
    if (!ns) {
        fprintf(stderr, "获取命名空间失败\n");
        return 1;
    }

    printf("NVMe 设备: %s, NS %d, 容量: %lu GB\n",
           spdk_nvme_ctrlr_get_name(ctrlr),
           spdk_nvme_ns_get_id(ns),
           spdk_nvme_ns_get_size(ns) / 1000000000);

    // Step 5: 启动轮询线程（可以用 spdk_thread）
    // 这里简化处理，实际用 spdk_thread_create
    printf("启动 NVMe 轮询...\n");
    while (1) sleep(1);

    spdk_nvme_ctrlr_disconnect(ctrlr);
    spdk_env_fini();
    return 0;
}
````

---

## 3. SPDK bdev 抽象层

### 3.1 bdev 架构

```
SPDK bdev 抽象层：

              ┌──────────────────┐
              │    应用          │
              │   (Blobstore/    │
              │   文件系统/DB)   │
              └────────┬─────────┘
                       │ bdev_read/bdev_write
                       ▼
┌────────────────────────────────────────────────────────────┐
│                    bdev 抽象层（io_device）                 │
│                                                            │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐      │
│   │ NVMe    │  │ malloc  │  │ AIO     │  │ Null    │      │
│   │ bdev    │  │ bdev    │  │ bdev    │  │ bdev    │      │
│   └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘      │
│        │            │            │            │             │
│        └────────────┴────────────┴────────────┘             │
│                           │                                  │
│                    ┌──────▼──────┐                          │
│                    │ bdev module │                          │
│                    │ (registered)│                          │
│                    └─────────────┘                           │
└────────────────────────────────────────────────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
┌─────────────────────────┐  ┌─────────────────────────┐
│   用户态 NVMe 驱动      │  │   其他存储后端           │
│   (PCIe BAR / DMA)      │  │   (kernel AIO / file)   │
└─────────────────────────┘  └─────────────────────────┘

bdev 的核心 API：
  struct spdk_bdev {
      const char *name;           // 设备名（如 NVMe0n1）
      const char *product_name;   // 产品名
      uint64_t blocklen;          // 块大小（通常 512 或 4096）
      uint64_t blockcnt;         // 总块数
      uint32_t md_len;           // metadata 长度
      // ...
  };

  // 读写接口
  int spdk_bdev_read(struct spdk_bdev_desc *desc,
                     struct spdk_bdev_channel *ch,
                     void *buf, uint64_t offset, uint64_t nbytes,
                     spdk_bdev_io_completion_cb cb, void *cb_arg);

  int spdk_bdev_write(struct spdk_bdev_desc *desc,
                      struct spdk_bdev_channel *ch,
                      void *buf, uint64_t offset, uint64_t nbytes,
                      spdk_bdev_io_completion_cb cb, void *cb_arg);
```

### 3.2 创建 NVMe bdev

```c
// spdk_bdev_nvme.c — 创建 NVMe bdev

#include <spdk/stdinc.h>
#include <spdk/bdev.h>
#include <spdk/nvme.h>

// bdev 名称
static struct spdk_bdev *g_bdev;

// I/O 完成回调
static void
io_complete(struct spdk_bdev_io *bdev_io, bool success, void *cb_arg)
{
    if (success) {
        printf("I/O 完成成功\n");
    } else {
        printf("I/O 完成失败\n");
    }
    spdk_bdev_free_io(&bdev_io);
}

// Poller：轮询 I/O 完成
static void
poll_bdev(void *arg)
{
    struct spdk_bdev_desc *desc = arg;

    while (1) {
        // 处理已完成的 I/O
        spdk_bdev_process_completions(desc, 0);
        usleep(1000);  // 1ms 轮询间隔
    }
}

int create_nvme_bdev(const char *pci_addr)
{
    struct spdk_nvme_transport_id trid = {0};
    trid.trtype = SPDK_NVME_TRANSPORT_PCIE;
    snprintf(trid.traddr, sizeof(trid.traddr), "%s", pci_addr);

    // 分配 bdev
    struct spdk_bdev **bdev_out;
    int rc = spdk_bdev_nvme_create(trid.traddr, NULL, "NVMe0n1", &bdev_out);
    if (rc < 0) {
        fprintf(stderr, "创建 NVMe bdev 失败\n");
        return rc;
    }

    g_bdev = *bdev_out;
    printf("NVMe bdev 创建成功: %s\n", g_bdev->name);
    printf("  块大小: %lu\n", g_bdev->blocklen);
    printf("  总块数: %lu\n", g_bdev->blockcnt);
    printf("  容量: %lu GB\n", g_bdev->blockcnt * g_bdev->blocklen / 1e9);

    // 打开 bdev 用于读写
    struct spdk_bdev_desc *desc;
    rc = spdk_bdev_open(g_bdev, true, NULL, NULL, &desc);
    if (rc < 0) {
        fprintf(stderr, "打开 bdev 失败\n");
        return rc;
    }

    // 获取 channel（每个线程一个）
    struct spdk_bdev_channel *ch;
    ch = spdk_bdev_get_io_channel(desc);
    if (!ch) {
        fprintf(stderr, "获取 channel 失败\n");
        return -1;
    }

    // 分配 DMA 缓冲区（SPDK 自动管理）
    void *buf = spdk_dma_malloc(4096, 4096, NULL);
    if (!buf) {
        fprintf(stderr, "分配 DMA 缓冲区失败\n");
        return -1;
    }
    memset(buf, 'A', 4096);

    // 写入数据
    rc = spdk_bdev_write(desc, ch, buf, 0, 4096, io_complete, NULL);
    if (rc < 0) {
        fprintf(stderr, "提交写入失败\n");
        return rc;
    }

    printf("写入已提交，等待完成...\n");

    // 启动轮询
    poll_bdev(desc);

    spdk_dma_free(buf);
    spdk_put_io_channel(ch);
    spdk_bdev_close(desc);
    return 0;
}
```

---

## 4. SPDK Blobstore

### 4.1 Blobstore 架构

```
SPDK Blobstore = SPDK 内置的 KV + 文件系统

设计目标：
  · 提供比裸 bdev 更高的语义
  · 支持持久化 KV 对（类似 RocksDB）
  · 支持文件/目录语义
  · 事务支持（write-ahead log）

架构：
┌─────────────────────────────────────────────────────────────┐
│                    Blobstore 层                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                 Blobfs（文件系统模式）               │  │
│  │  · 目录条目      · 文件数据                          │  │
│  │  · 元数据缓存   · POSIX-like 接口                   │  │
│  └───────────────────────┬──────────────────────────────┘  │
│                          │                                    │
│  ┌───────────────────────▼──────────────────────────────┐  │
│  │                  Blob（数据块）                       │  │
│  │  · 持久化数据结构  · 分配器                          │  │
│  │  · Cluster 分配    · 元数据                          │  │
│  └───────────────────────┬──────────────────────────────┘  │
│                          │                                    │
│  ┌───────────────────────▼──────────────────────────────┐  │
│  │                  bdev（底层块设备）                   │  │
│  │  · NVMe bdev      · malloc bdev                     │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘

Blob 的结构：
  ┌──────────────────────────────────────────────────────┐
  │  Blob Header                                         │
  │  ├─ magic: 0xBLOB0 (blob 标识)                      │
  │  ├─ type: 稀疏文件 / 快照 / 克隆                     │
  │  ├─ length: 总长度                                  │
  │  ├─ capacity: 分配的 cluster 数                     │
  │  └─ used_cnt: 实际使用的 cluster 数                 │
  ├──────────────────────────────────────────────────────┤
  │  Cluster Bitmap                                     │
  │  ├─ 哪些 cluster 已分配                              │
  │  └─ 每个 cluster 1 bit                             │
  ├──────────────────────────────────────────────────────┤
  │  Data Clusters                                       │
  │  ├─ Cluster 0: 数据                                  │
  │  ├─ Cluster 1: 数据                                  │
  │  └─ ...                                              │
  └──────────────────────────────────────────────────────┘

Cluster 大小：
  · 默认 3MB（SPDK_BLOBSTORE_DEFAULT_CLUSTER_SIZE）
  · 可配置 1MB-128MB
```

### 4.2 Blobstore 基本操作

```c
// spdk_blobstore_example.c — Blobstore 基本操作

#include <spdk/stdinc.h>
#include <spdk/blob.h>
#include <spdk/bdev.h>

static struct spdk_blob_store *g_bs;
static spdk_blob_id g_blob_id;

// 打开 bdev 并创建 blobstore
static void
create_bs_complete(void *cb_arg, struct spdk_blob_store *bs, int bserrno)
{
    if (bserrno != 0) {
        fprintf(stderr, "创建 blobstore 失败: %d\n", bserrno);
        return;
    }
    g_bs = bs;
    printf("Blobstore 创建成功！\n");
}

static void
open_bs_complete(void *cb_arg, struct spdk_blob_store *bs, int bserrno)
{
    if (bserrno != 0) {
        fprintf(stderr, "打开 blobstore 失败: %d\n", bserrno);
        return;
    }
    g_bs = bs;
    printf("Blobstore 打开成功！\n");
}

// 写入 blob（异步）
static void
write_blob_complete(struct spdk_blob_object *obj, int bserrno)
{
    if (bserrno != 0) {
        fprintf(stderr, "写入 blob 失败: %d\n", bserrno);
        return;
    }
    printf("Blob 写入完成！\n");
}

int blobstore_example(void)
{
    struct spdk_bdev *bdev;  // 假设已创建

    // Step 1: 创建或打开 blobstore
    struct spdk_bs_dev *bs_dev = spdk_bdev_create_bs_dev(bdev, NULL, NULL);
    if (!bs_dev) {
        fprintf(stderr, "创建 bs_dev 失败\n");
        return -1;
    }

    // 尝试打开现有 blobstore
    int rc = spdk_bs_load(bs_dev, open_bs_complete, NULL);
    if (rc < 0) {
        // 不存在，创建新的
        printf("创建新 blobstore...\n");
        struct spdk_bs_opts opts = {0};
        spdk_bs_opts_init(&opts);
        opts.cluster_sz = 3 * 1024 * 1024;  // 3MB cluster
        opts.num_md_pages = 256;

        rc = spdk_bs_init(bs_dev, &opts, create_bs_complete, NULL);
    }

    // 等待创建/打开完成（简化，实际用事件循环）
    sleep(1);

    // Step 2: 创建 blob
    struct spdk_blob *blob;
    struct spdk_blob_opts blob_opts = {0};
    spdk_blob_opts_init(&blob_opts);
    blob_opts.num_clusters = 10;  // 分配 10 个 cluster（30MB）

    rc = spdk_bs_create_blob(g_bs, &blob_opts, &blob);
    if (rc < 0) {
        fprintf(stderr, "创建 blob 失败: %d\n", rc);
        return rc;
    }

    g_blob_id = spdk_blob_get_id(blob);
    printf("Blob 创建成功，ID: %lu\n", g_blob_id);

    // Step 3: 写入数据到 blob
    void *buf = spdk_dma_malloc(4096, 4096, NULL);
    memset(buf, 'X', 4096);

    struct spdk_blob_object obj = {0};
    obj.blob_id = g_blob_id;

    rc = spdk_blob_write(&obj, 0, buf, 4096, write_blob_complete, NULL);
    if (rc < 0) {
        fprintf(stderr, "写入 blob 失败: %d\n", rc);
        return rc;
    }

    sleep(1);  // 等待写入完成

    // Step 4: 读取数据
    memset(buf, 0, 4096);
    rc = spdk_blob_read(&obj, 0, buf, 4096, NULL, NULL);
    printf("读取数据: %.4096s\n", (char *)buf);

    // Step 5: 同步 blob（持久化）
    spdk_blob_sync(&obj);

    // Step 6: 删除 blob
    spdk_bs_delete_blob(g_bs, g_blob_id, NULL);

    // Step 7: 卸载 blobstore
    spdk_bs_unload(g_bs, NULL, NULL);

    spdk_dma_free(buf);
    return 0;
}
```

---

## 5. SPDK NVMe-oF Target

### 5.1 NVMe-oF Target vs 内核 nvmet

```
SPDK NVMe-oF Target vs Linux 内核 nvmet：

┌────────────────────────────────────────────────────────────────┐
│              内核 nvmet                │  SPDK nvmf           │
├────────────────────────────────────────┼──────────────────────┤
│  路径            内核网络栈 + 内核驱动  │  用户态轮询          │
│  中断            MSI-X 中断处理        │  零中断（poll mode） │
│  CPU 占用        较高（中断 + 上下文） │  可控（绑定专用核）  │
│  延迟            ~15-20us (TCP)        │  ~10-15us (TCP)     │
│  吞吐量          稍低                   │  更高                │
│  配置复杂度      简单（configfs）       │  复杂（代码/RPC）   │
│  扩展性          好                     │  非常好              │
│  RDMA 支持      原生                   │  原生                │
└────────────────────────────────────────┴──────────────────────┘

SPDK nvmf 架构：

┌─────────────────────────────────────────────────────────────┐
│                  SPDK nvmf 架构                            │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Fabric 传输层                          │    │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐        │    │
│  │  │ RDMA     │  │ TCP      │  │ FC       │        │    │
│  │  │ (libibverbs)│ │ (sock)  │  │ (libfc)  │        │    │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘        │    │
│  └────────┼───────────┼──────────────┼────────────────┘    │
│           │           │              │                       │
│  ┌────────▼───────────▼──────────────▼────────────────┐    │
│  │              Subsystem 层                           │    │
│  │  · NQN / Namespace 管理                             │    │
│  │  · 访问控制（ANA/ACLS）                            │    │
│  │  · NVMe-oF 协议解析                                │    │
│  └─────────────────────┬───────────────────────────────┘    │
│                        │                                     │
│  ┌─────────────────────▼───────────────────────────────┐   │
│  │              bdev 层                                 │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐             │   │
│  │  │ NVMe   │  │ malloc  │  │ Blobstore│             │   │
│  │  │ bdev   │  │ bdev    │  │         │             │   │
│  │  └─────────┘  └─────────┘  └─────────┘             │   │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 SPDK nvmf 配置

```bash
# ========== SPDK nvmf target 启动脚本 ==========

#!/usr/bin/env bash

# 启动参数
export SPDK.shm_id=0
export SPDK.no_ocf=1
export SPDK.dpdk_core_mask=0x3       # 使用 CPU 核 0-1
export SPDK.mem_size=4096             # 4GB 内存用于 DPDK

# hugepage（必需，DPDK 内存）
mkdir -p /dev/hugepages
mount -t hugetlbfs hugetlbfs /dev/hugepages
echo 4096 > /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages

# 绑定 NVMe 到 vfio-pci（用户态驱动）
modprobe vfio-pci

# 运行 SPDK nvmf target
/app/spdk/build/bin/nvmf_tgt &
# 后台运行

sleep 3

# 通过 RPC 配置 nvmf subsystem
/app/spdk/scripts/rpc.py nvmf_create_transport -t RDMA -u 131072
# -t RDMA: RDMA 传输
# -u 131072: 最大 I/O 队列深度

# 创建 NVMe 子系统
/app/spdk/scripts/rpc.py nvmf_create_subsystem nqn.2014-08.io.spdk:nvme0 \
    -a -s SPDK0001

# 添加命名空间（使用 blobstore 作为后端）
/app/spdk/scripts/rpc.py bdev_malloc_create -b Malloc0 256 512
# -b: bdev 名称
# 256: 盘大小（MB）
# 512: 块大小（字节）

/app/spdk/scripts/rpc.py nvmf_subsystem_add_ns nqn.2014-08.io.spdk:nvme0 Malloc0

# 监听 RDMA 端口
/app/spdk/scripts/rpc.py nvmf_subsystem_add_listener nqn.2014-08.io.spdk:nvme0 \
    -t rdma -a 192.168.1.100 -s 4420
# -t: 传输类型
# -a: IP 地址
# -s: 端口

echo "NVMe-oF Target 已启动，监听 192.168.1.100:4420 (RDMA)"
```

### 5.3 SPDK nvmf 性能数据

```
SPDK nvmf vs 内核 nvmet 性能对比（100GbE RoCE v2）：

测试配置：
  · CPU: Intel Xeon Gold 6248R
  · NIC: Mellanox ConnectX-6 HDR
  · SSD: Intel Optane P4800X (375GB)
  · 协议: NVMe/RDMA

单线程延迟（4KB 读）：
              平均        P99        P99.9
────────────────────────────────────────────────
SPDK nvmf     8.5us      12us       18us
内核 nvmet    14us       22us       35us
────────────────────────────────────────────────
  提升          39%        45%        48%

多核扩展（16 线程，32 队列）：
              IOPS        带宽        CPU%
────────────────────────────────────────────────
SPDK nvmf     1.8M       7.2 GB/s    35%
内核 nvmet    1.2M       4.8 GB/s    58%
────────────────────────────────────────────────
  提升          50%        50%        -40% (CPU 节省)

原因分析：
  · SPDK nvmf 零中断，CPU 用于数据处理而非调度
  · 每个 lcore 独立队列，无锁竞争
  · 内存预分配，避免运行时分配开销
```

---

## 6. SPDK vhost-blk

### 6.1 vhost-user 架构

```
vhost-user = virtio 设备的用户态实现

传统 virtio：
  ┌──────────┐      ┌──────────────┐      ┌──────────┐
  │  QEMU    │ ←──→ │  vhost-net   │ ←──→ │   NIC    │
  │  (virtio) │      │  (kernel)    │      │          │
  └──────────┘      └──────────────┘      └──────────┘

vhost-user：
  ┌──────────┐      ┌──────────────┐      ┌──────────┐
  │  QEMU    │ ←──→ │  Unix Socket │ ←──→ │  SPDK    │
  │  (virtio) │      │  (控制面)    │      │ vhost-blk│
  └──────────┘                              └────┬─────┘
                                                  │
                                                  ▼
                                            ┌──────────┐
                                            │  NVMe   │
                                            │  bdev   │
                                            └──────────┘

vhost-blk 优势：
  · VM 的 virtio-blk 直接访问 SPDK NVMe bdev
  · 绕过宿主机内核（零拷贝可能）
  · 低延迟：VM → SPDK（用户态）→ NVMe
  · 高 IOPS：充分利用 SPDK poll mode
```

### 6.2 vhost-blk 配置

```bash
#!/bin/bash
# 启动 SPDK vhost-blk

# 1. 创建 NVMe bdev
/app/spdk/scripts/rpc.py bdev_nvme_attach_controller \
    -b NVMe0 -t PCIe -a 0000:01:00.0

# 2. 创建 vhost 控制器
/app/spdk/scripts/rpc.py vhost_create_controller \
    -c vhost0 -n nvme

# 3. 添加块设备到 vhost
/app/spdk/scripts/rpc.py vhost_add_blk_controller \
    -c vhost0 -b NVMe0n1 -n nvme0

# 4. QEMU 启动 VM，使用 vhost-user-blk
qemu-system-x86_64 \
    -m 4G \
    -object memory-backend-file,id=mem0,size=4G,mem-path=/dev/hugepages \
    -device virtio-mem-pci,id=vm0,size=4G,memdev=mem0 \
    -chardev socket,id=char0,path=/var/tmp/vhost0.sock \
    -device vhost-user-blk-pci,chardev=char0 \
    -numa node,memdev=mem0
```

---

## 7. io_uring 与 SPDK 的融合

### 7.1 为什么需要融合

```
io_uring + SPDK 的互补：

io_uring 优势：
  · Linux 原生，无需特殊驱动
  · 消除 syscall 开销（~200ns）
  · 成熟稳定，内核生态完善
  · 跨平台（Linux 5.1+）

SPDK 优势：
  · 用户态驱动，绕过内核
  · Poll mode，零中断
  · 极低延迟（~8us vs ~15us）
  · 成熟的企业级存储框架

融合的价值：
  ┌────────────────────────────────────────────────────────────┐
  │                      融合架构                              │
  │                                                            │
  │   io_uring (系统调用优化)                                  │
  │        │                                                   │
  │        ▼                                                   │
  │   SPDK NVMe Driver (用户态轮询)  ←── 两者在这里融合        │
  │        │                                                   │
  │        ▼                                                   │
  │   PCIe DMA → NVMe SSD                                     │
  └────────────────────────────────────────────────────────────┘

融合点：
  1. SPDK 使用 io_uring 替代 poll group（Linux 环境）
  2. io_uring 使用 SPDK 驱动访问 NVMe（SPDK 驱动绑定到设备）
  3. 混合部署：io_uring 处理网络，SPDK 处理本地 NVMe
```

### 7.2 SPDK io_uring 集成

```c
// spdk_io_uring.c — SPDK 使用 io_uring 处理完成事件

#include <spdk/stdinc.h>
#include <spdk/env.h>
#include <liburing.h>

static struct io_uring ring;

int spdk_uring_init(void)
{
    // 初始化 io_uring（SPDK 内部用它做异步通知）
    struct io_uring_params params = {0};
    params.flags = IORING_SETUP_SQPOLL;  // 内核轮询 sq
    params.sq_thread_idle = 1000;         // 1s idle 后休眠

    int rc = io_uring_queue_init_params(256, &ring, &params);
    if (rc < 0) {
        fprintf(stderr, "io_uring 初始化失败: %s\n", strerror(-rc));
        return rc;
    }

    printf("io_uring 初始化成功！\n");
    return 0;
}

// 通过 io_uring 等待 NVMe 完成
int spdk_uring_wait_completion(struct spdk_nvme_ctrlr *ctrlr)
{
    struct io_uring_cqe *cqe;

    // io_uring 等待（超时 1ms）
    int rc = io_uring_wait_cqe_timeout(&ring, &cqe, &(struct __kernel_timespec){0, 1000000});
    if (rc < 0 && rc != -EAGAIN) {
        fprintf(stderr, "io_uring wait 错误: %s\n", strerror(-rc));
        return rc;
    }

    if (rc == 0) {
        // 有完成事件
        uint32_t *ptr = (uint32_t *)((char *)cqe->user_data);
        // 处理完成...
        io_uring_cqe_seen(&ring, cqe);
    }

    // 继续处理 NVMe qpair
    struct spdk_nvme_qpair *qpair;
    TAILQ_FOREACH(qpair, &ctrlr->nvme_qpairs, tailq) {
        spdk_nvme_qpair_process_completions(qpair, 0);
    }

    return 0;
}
```

### 7.3 性能对比总结

```
io_uring vs SPDK NVMe 延迟分解：

路径：
  应用 → io_uring → 内核 NVMe 驱动 → PCIe DMA → NVMe SSD
  应用 → SPDK lib → 用户态轮询 → PCIe DMA → NVMe SSD

单次 4KB 读延迟分解：

  ┌─────────────────────────────────────────────────────────┐
  │                      io_uring                          │
  ├─────────────────────────────────────────────────────────┤
  │  syscall (io_uring_enter)     ~50ns                    │
  │  内核 nvme_submit_cmd         ~200ns                  │
  │  内核中断处理（首次）          ~1-2us                  │
  │  PCIe DMA 往返                 ~1us                   │
  │  NVMe 命令处理                 ~5us                   │
  │  ─────────────────────────────────────────             │
  │  总计                          ~8-9us                 │
  └─────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────┐
  │                      SPDK                              │
  ├─────────────────────────────────────────────────────────┤
  │  直接函数调用（无 syscall）      ~10ns                  │
  │  用户态 NVMe 命令构造           ~50ns                  │
  │  PCIe DMA 往返                  ~1us                   │
  │  NVMe 命令处理                  ~5us                   │
  │  ─────────────────────────────────────────             │
  │  总计                          ~6-7us                  │
  └─────────────────────────────────────────────────────────┘

结论：
  · SPDK 比 io_uring 快约 20-30%（~2us）
  · 主要差距：io_uring 仍需内核参与，SPDK 完全用户态
  · 但 SPDK 需要专用驱动，不支持所有 NVMe SSD
```

---

## 8. 小结

```
SPDK 用户态 NVMe 框架：

为什么需要用户态 NVMe：
  内核 NVMe 开销：syscall（~200ns）+ 中断（~1-5us）
  SPDK：绕过内核，零中断，poll mode

SPDK 核心组件：
  env/          — 初始化、DPDK、内存管理
  nvme/         — 用户态 NVMe 驱动
  bdev/         — 块设备抽象层
  blobstore/    — KV + 文件系统
  nvmf/         — NVMe-oF Target
  vhost/        — vhost-user 实现
  app/          — 事件循环

bdev 抽象层：
  统一接口访问不同后端（NVMe/malloc/AIO/blobstore）
  API: spdk_bdev_read/write/flush/trim

Blobstore：
  持久化 KV + 文件系统
  Cluster 分配，元数据持久化
  适用：数据库、日志、需要高级语义的场景

NVMe-oF Target (nvmf)：
  SPDK nvmf vs 内核 nvmet：
    · 零中断，CPU 利用率更低
    · 延迟低 30-40%
    · 配置复杂，需要更多资源
  支持 RDMA/TCP 传输

vhost-blk：
  VM virtio-blk 直接访问 SPDK bdev
  绕过宿主机内核，VM → SPDK → NVMe

io_uring + SPDK 融合：
  互补：io_uring 优化 syscall，SPDK 优化中断
  融合方式：SPDK 内部用 io_uring 做通知
  延迟：io_uring ~8us，SPDK ~6us（差距 20-30%）
```

---

## 延伸阅读

- SPDK 官网: `https://spdk.io/`
- SPDK GitHub: `https://github.com/spdk/spdk`
- SPDK 文档: `https://spdk.io/doc/`
- SPDK NVMe 驱动: `lib/nvme/nvme.c`
- SPDK bdev 层: `lib/bdev/bdev.c`
- SPDK Blobstore: `lib/blobstore/blobstore.c`
- SPDK nvmf: `lib/nvmf/`
- DPDK: `https://www.dpdk.org/` (SPDK 基于 DPDK)
- LWN: "SPDK: Storage Performance Development Kit": https://lwn.net/Articles/740214/
- LWN: "Userspace NVMe": https://lwn.net/Articles/757939/
