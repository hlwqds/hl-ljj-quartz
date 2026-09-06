---
title: "DPDK 深度探索 ch45：RDMA 与 DPDK"
date: 2026-04-10 18:00:00
tags: [dpdk, rdma, infiniband, roce, verbs, wqe, mr, pd, cq]
description: "深入解析 DPDK RDMA：RDMA 概述、Verbs API、Memory Region、Queue Pair、RoCE 与 DPDK 集成"
---

# DPDK 深度探索 ch45：RDMA 与 DPDK

> [!abstract] 核心要点
> RDMA 是高性能网络的关键技术。本章深入解析 RDMA 原理、Verbs API、Memory Region、Queue Pair、RoCE 与 DPDK 集成。

## 1. RDMA 概述

### 1.1 什么是 RDMA

```
RDMA (Remote Direct Memory Access):

┌─────────────────────────────────────────────────────────────┐
│                    传统 vs RDMA                            │
│                                                              │
│  传统 (TCP/IP):                                            │
│  ┌────────┐      ┌────────┐      ┌────────┐                 │
│  │App CPU │ ──▶ │Kernel  │ ──▶ │ NIC   │                 │
│  │        │      │ (copy) │      │ (DMA) │                 │
│  └────────┘      └────────┘      └────────┘                 │
│                                                              │
│  延迟: ~10-100 μs                                           │
│  CPU 开销: 高                                               │
│                                                              │
│  RDMA:                                                      │
│  ┌────────┐                    ┌────────┐                    │
│  │App CPU │ ─────────────────▶│  NIC   │                    │
│  │        │      (零拷贝)      │ (DMA)  │                    │
│  └────────┘                    └────────┘                    │
│                                                              │
│  延迟: ~1-10 μs                                             │
│  CPU 开销: 极低                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 RDMA 优势

| 特性         | 传统网络  | RDMA        |
| ------------ | --------- | ----------- |
| **延迟**     | 10-100 μs | 1-10 μs     |
| **CPU 开销** | 高        | 极低        |
| **吞吐**     | 受限 CPU  | 线速        |
| **可靠性**   | TCP 保证  | IB 可靠传输 |
| **内存拷贝** | 多次      | 零拷贝      |

### 1.3 RDMA 网络

```
RDMA 网络类型：

1. InfiniBand
   - 专用 IB 网络
   - 业界领先性能
   - HDR: 200/400 Gbps

2. RoCE (RDMA over Converged Ethernet)
   - RoCE v1: L2 only
   - RoCE v2: L3 (IP) 支持
   - 需要网络支持 PFC/DCBX

3. iWARP
   - TCP 承载 RDMA
   - 兼容性最好
   - 性能略低
```

## 2. 基本概念

### 2.1 核心组件

```
┌─────────────────────────────────────────────────────────────┐
│                    RDMA 核心组件                            │
│                                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │   PD     │  │   MR     │  │   QP     │  │   CQ     │  │
│  │Protection│  │ Memory   │  │  Queue   │  │ Completion│  │
│  │ Domain   │  │ Region   │  │  Pair    │  │   Queue   │  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │
│                                                              │
│  PD: 保护域，隔离资源                                       │
│  MR: 内存区域，可被远程访问的内存                           │
│  QP: 队列对，通信端点                                       │
│  CQ: 完成队列，异步事件通知                                 │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Verbs

```
Verbs = RDMA API

主要 Verbs:

1. 资源管理
   - ibv_alloc_pd: 分配保护域
   - ibv_create_cq: 创建完成队列
   - ibv_create_qp: 创建队列对
   - ibv_reg_mr: 注册内存区域

2. 通信
   - ibv_post_send: 发送 Work Request
   - ibv_post_recv: 接收 Work Request
   - ibv_poll_cq: 轮询完成队列

3. 控制
   - ibv_modify_qp: 修改 QP 状态
   - ibv_query_qp: 查询 QP 状态
   - ibv_ack_cq_events: 确认完成事件
```

## 3. DPDK RDMA 支持

### 3.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DPDK RDMA 架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              RDMA Core (librdma)                     │  │
│  │                                                       │  │
│  │  - Verbs API 封装                                   │  │
│  │  - Memory management                                 │  │
│  │  - Queue management                                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              RDMA Drivers                             │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐        │  │
│  │  │  mlx5   │  │  bnxt   │  │   hns   │        │  │
│  │  │ (Mellanox)│  │(Broadcom)│  │ (Huawei) │        │  │
│  │  └──────────┘  └──────────┘  └──────────┘        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 初始化

```c
#include <rte_ethdev.h>
#include <rdma/rte_rdma.h>

// RDMA 设备发现
int
rdma_device_discovery(void)
{
    struct rte_rdma_device_info info;
    uint8_t nb_devices = rte_rdma_dev_count();

    printf("RDMA devices: %u\n", nb_devices);

    for (uint8_t i = 0; i < nb_devices; i++) {
        if (rte_rdma_dev_info_get(i, &info) == 0) {
            printf("Dev %u: %s\n", i, info.name);
            printf("  Vendor: %x\n", info.vendor_id);
            printf("  Max QP: %u\n", info.max_qp);
            printf("  Max MR: %u\n", info.max_mr);
        }
    }

    return nb_devices;
}
```

## 4. Memory Region (MR)

### 4.1 注册内存

```c
#include <rdma/rte_rdma.h>

// 内存注册
struct rte_rdma_mr *
register_memory(void *addr, size_t length)
{
    struct rte_rdma_mr_init_attr attr = {
        .addr = addr,
        .length = length,
        .access = RTE_RDMA_ACCESS_LOCAL_WRITE |   // 本地写
                  RTE_RDMA_ACCESS_REMOTE_WRITE |  // 远程写
                  RTE_RDMA_ACCESS_REMOTE_READ,    // 远程读
    };

    return rte_rdma_mr_register(&attr);
}

// 获取 lkey/rkey
uint32_t
get_lkey(struct rte_rdma_mr *mr)
{
    return mr->lkey;
}

uint32_t
get_rkey(struct rte_rdma_mr *mr)
{
    return mr->rkey;
}
```

### 4.2 DPDK mbuf RDMA

```c
// 为 mbuf 注册 RDMA
struct rte_rdma_mr *
register_mbuf_memory(struct rte_mbuf *pkt)
{
    void *addr = rte_pktmbuf_mtod(pkt, void *);
    size_t len = rte_pktmbuf_data_len(pkt);

    struct rte_rdma_mr_init_attr attr = {
        .addr = addr,
        .length = len,
        .access = RTE_RDMA_ACCESS_LOCAL_WRITE,
    };

    return rte_rdma_mr_register(&attr);
}
```

## 5. Queue Pair (QP)

### 5.1 创建 QP

```c
// 创建 Queue Pair
struct rte_rdma_qp *
create_qp(uint8_t dev_id, struct rte_rdma_pd *pd)
{
    struct rte_rdma_qp_init_attr attr = {
        .qp_type = RTE_RDMA_QP_TYPE_RC,  // Reliable Connected
        .send_cq = cq,                   // 发送完成队列
        .recv_cq = cq,                   // 接收完成队列
        .cap = {
            .max_send_wr = 128,          // 最大发送 WR
            .max_recv_wr = 128,          // 最大接收 WR
            .max_send_sge = 4,           // 最大发送 SGE
            .max_recv_sge = 4,           // 最大接收 SGE
        },
    };

    return rte_rdma_qp_create(pd, &attr);
}
```

### 5.2 QP 状态机

```
┌─────────────────────────────────────────────────────────────┐
│                    QP 状态机                                │
│                                                              │
│  RESET ──▶ INIT ──▶ RTR ──▶ RTS                            │
│     │         │         │         │                         │
│     │         │         │         │                         │
│     │         ▼         ▼         ▼                         │
│     │       RESET     RESET     RESET                      │
│     │                                                 │
│  RTS ──▶ ERROR                                        │
│                                                              │
│  RESET: 初始化状态                                         │
│  INIT:  初始化完成，准备接收                              │
│  RTR:   Ready to Receive                                  │
│  RTS:   Ready to Send                                     │
│  ERROR: 错误状态                                           │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 修改 QP

```c
// 修改 QP 到 INIT
int
qp_to_init(struct rte_rdma_qp *qp)
{
    struct rte_rdma_qp_attr attr = {
        .qp_state = RTE_RDMA_QP_STATE_INIT,
        .pkey_index = 0,
        .port_num = 1,
        .sq_psn = 0,  // Starting PSN
    };

    return rte_rdma_qp_modify(qp, &attr);
}

// 修改 QP 到 RTR (Ready to Receive)
int
qp_to_rtr(struct rte_rdma_qp *qp,
          uint32_t remote_qp_num,
          uint8_t port_num,
          uint32_t remote_lid,
          uint32_t dest_qp_num)
{
    struct rte_rdma_qp_attr attr = {
        .qp_state = RTE_RDMA_QP_STATE_RTR,
        .path_mtu = RTE_RDMA_MTU_4096,
        .rq_psn = 0,
        .dest_qp_num = dest_qp_num,
        .rq_psn = 0,
    };

    return rte_rdma_qp_modify(qp, &attr);
}
```

## 6. RDMA 操作

### 6.1 发送/接收

```c
// 发送操作
int
post_send(struct rte_rdma_qp *qp,
          void *addr, size_t length,
          uint32_t rkey, uint64_t remote_addr,
          uint32_t lkey)
{
    struct rte_rdma_send_wr wr = {
        .sg_list = &(struct rte_rdma_sge){
            .addr = (uint64_t)addr,
            .length = length,
            .lkey = lkey,
        },
        .num_sge = 1,
        .opcode = RTE_RDMA_WR_SEND,
        .send_flags = RTE_RDMA_SEND_SIGNALED,  // 需要完成通知
    };

    return rte_rdma_qp_post_send(qp, &wr);
}

// 接收操作
int
post_recv(struct rte_rdma_qp *qp,
          void *addr, size_t length,
          uint32_t lkey)
{
    struct rte_rdma_recv_wr wr = {
        .sg_list = &(struct rte_rdma_sge){
            .addr = (uint64_t)addr,
            .length = length,
            .lkey = lkey,
        },
        .num_sge = 1,
    };

    return rte_rdma_qp_post_recv(qp, &wr);
}
```

### 6.2 RDMA Read/Write

```c
// RDMA Read (从远程读取)
int
rdma_read(struct rte_rdma_qp *qp,
          void *local_addr, size_t length,
          uint32_t rkey, uint64_t remote_addr,
          uint32_t lkey)
{
    struct rte_rdma_send_wr wr = {
        .sg_list = &(struct rte_rdma_sge){
            .addr = (uint64_t)local_addr,
            .length = length,
            .lkey = lkey,
        },
        .num_sge = 1,
        .opcode = RTE_RDMA_WR_RDMA_READ,
        .wr.rdma = {
            .rkey = rkey,
            .remote_addr = remote_addr,
        },
        .send_flags = RTE_RDMA_SEND_SIGNALED,
    };

    return rte_rdma_qp_post_send(qp, &wr);
}

// RDMA Write (写入远程)
int
rdma_write(struct rte_rdma_qp *qp,
           void *local_addr, size_t length,
           uint32_t rkey, uint64_t remote_addr,
           uint32_t lkey)
{
    struct rte_rdma_send_wr wr = {
        .sg_list = &(struct rte_rdma_sge){
            .addr = (uint64_t)local_addr,
            .length = length,
            .lkey = lkey,
        },
        .num_sge = 1,
        .opcode = RTE_RDMA_WR_RDMA_WRITE,
        .wr.rdma = {
            .rkey = rkey,
            .remote_addr = remote_addr,
        },
        .send_flags = RTE_RDMA_SEND_SIGNALED,
    };

    return rte_rdma_qp_post_send(qp, &wr);
}
```

### 6.3 完成轮询

```c
// 轮询完成队列
int
poll_cq(struct rte_rdma_cq *cq)
{
    struct rte_rdma_comp *comp;
    int ret;

    while ((ret = rte_rdma_cq_pop(cq, &comp)) == 0) {
        if (comp->status == RTE_RDMA_COMP_SUCCESS) {
            printf("WR %lu completed\n", comp->wr_id);
        } else {
            printf("WR %lu failed: %d\n",
                   comp->wr_id, comp->status);
        }
    }

    return ret == 1 ? 0 : ret;  // 1 = empty
}
```

## 7. RoCE

### 7.1 RoCE 配置

```
RoCE v2 (Routable RoCE):

┌─────────────────────────────────────────────────────────────┐
│                    RoCE v2 头                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Ethernet Header                                     │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  IP Header                                           │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  UDP Header (dst port=4791)                         │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  IB BTH (Base Transport Header)                      │  │
│  ├──────────────────────────────────────────────────────┤  │
│  │  IB Payload                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 PFC (Priority Flow Control)

```bash
# 启用 PFC
# 交换机配置
# 启用 DCBX
# 设置 ETS
# 启用 PFC on priority 3

# 查看 DCB 状态
dcbtool sc0 pfc e

# 配置网卡 DCB
dcbtool sc0 dcbx on
dcbtool sc0 pfc on 3
```

## 8. 总结

RDMA vs Socket：

```
性能对比:

┌─────────────────────────────────────────────────────────────┐
│                    性能对比                                 │
│                                                              │
│  指标      │   Socket   │  RDMA (RoCE)  │   提升   │       │
│  ──────────┼────────────┼───────────────┼──────────┼─────│
│  延迟      │  50-100 μs │   2-10 μs     │   10x   │       │
│  CPU 使用  │   30-50%   │    5-10%      │   5x    │       │
│  吞吐量    │   5-8 Gbps │   25-100 Gbps│   5-20x │       │
│  消息率    │  100K-1M/s │  1M-10M/s    │   10x   │       │
└─────────────────────────────────────────────────────────────┘
```

DPDK + RDMA 场景：

| 场景                 | 优势           |
| -------------------- | -------------- |
| **存储 (NVMe-oF)**   | 极低延迟       |
| **AI/ML (集合通信)** | GPUDirect RDMA |
| **分布式缓存**       | 高吞吐         |
| **金融 (HFT)**       | 确定性延迟     |

---

## 参考资源

- [RDMA Consortium](https://www.rdmaconsortium.org/)
- [IBTA RoCE](https://www.infinibandta.org/roce/)
- [Mellanox RDMA](https://docs.nvidia.com/networking/)
