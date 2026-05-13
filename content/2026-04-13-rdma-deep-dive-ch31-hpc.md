---
title: "RDMA 第三十一章：HPC 集群——MPI + RDMA 构建超算网络"
date: 2026-04-13
tags: [rdma, hpc, mpi, infiniband, cluster, lustre, supercomputer, leadership]
description: "详解 HPC 超算集群中的 RDMA 应用：MPI 编程模型、OpenFabrics 协议栈、InfiniBand 集群架构、Lustre 并行文件系统、SHARP 集合操作加速、超算网络设计与性能优化。"
---

> [!abstract] 核心要点
> HPC（高性能计算）集群是 RDMA 最传统也是最成熟的应用领域。本章深入分析 MPI + RDMA 编程模型、InfiniBand 网络架构、OpenFabrics 软件栈、Lustre 并行文件系统、以及 HPC 集群的完整通信路径，为构建超算级 RDMA 网络提供实践指南。

---

## 1. HPC 集群概述

### 1.1 HPC 与 AI 训练的区别

```
HPC vs AI 训练 workload：

  ┌─────────────────────────────────────────────────────────────────┐
  │                        HPC 工作负载                              │
  │                                                                  │
  │  科学计算 / 物理模拟 / 气象预测                                  │
  │  - MPI 点对点和集合通信                                         │
  │  - 确定性计算                                                    │
  │  - 长期运行 (hours to weeks)                                     │
  │  - 精确浮点运算                                                  │
  │                                                                  │
  │  通信模式:                                                       │
  │  - MPI_Send / MPI_Recv (点对点)                                 │
  │  - MPI_AllReduce / MPI_Barrier (集合)                           │
  │  - 非结构化网格通信                                              │
  └─────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────┐
  │                      AI 训练工作负载                            │
  │                                                                  │
  │  深度学习训练 / 分布式数据并行                                  │
  │  - NCCL 集合通信                                                 │
  │  - 迭代式计算                                                    │
  │  - 中短期运行 (days to weeks)                                    │
  │  - 混合精度训练                                                  │
  │                                                                  │
  │  通信模式:                                                       │
  │  - AllReduce (梯度同步)                                         │
  │  - AllGather (参数收集)                                         │
  │  - 结构化张量分片                                                │
  └─────────────────────────────────────────────────────────────────┘
```

### 1.2 全球 HPC Top500 与 RDMA

```
Top500 超算网络统计 (2024):

  ┌─────────────────────────────────────────────────────────────────┐
  │                     网络技术分布                                 │
  │                                                                  │
  │  InfiniBand:     47.2%  (236 系统)                             │
  │  Ethernet:       32.4%  (162 系统)                              │
  │  Omni-Path:      12.8%  (64 系统)                               │
  │  Custom:          7.6%  (38 系统)                                │
  └─────────────────────────────────────────────────────────────────┘

  InfiniBand 超算代表:
  - Frontier (ORNL): AMD EPYC + InfiniBand HDR
  - LUMI (CSC): AMD EPYC + LUMI-D软件栈
  - Leonardo (CINECA): NVIDIA A100 + InfiniBand HDR
```

---

## 2. MPI 与 RDMA 集成

### 2.1 MPI 通信模型

```
MPI 通信模型：

  ┌─────────────────────────────────────────────────────────────────┐
  │                    MPI 应用程序                                 │
  │  ┌─────────────────────────────────────────────────────────┐   │
  │  │                                                         │   │
  │  │   MPI_Init()                                            │   │
  │  │   MPI_Comm_rank()  → 0..n-1                             │   │
  │  │   MPI_Comm_size()  → n processes                        │   │
  │  │                                                         │   │
  │  │   MPI_Send / MPI_Recv   (点对点)                         │   │
  │  │   MPI_AllReduce / MPI_Bcast  (集合)                      │   │
  │  │                                                         │   │
  │  │   MPI_Finalize()                                         │   │
  │  │                                                         │   │
  │  └─────────────────────────────────────────────────────────┘   │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                      OpenMPI / MPICH                            │
  │                                                                  │
  │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐  │
  │  │  OB1 (p2p)   │  │  Coll (collective)│  │  RMA (one-sided)  │  │
  │  │              │  │                  │  │                    │  │
  │  │  BTL Module  │  │  Coll Algorithm │  │   MPI_Win_create    │  │
  │  │              │  │  Selection      │  │                    │  │
  │  └──────────────┘  └──────────────┘  └──────────────────────┘  │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                    OpenFabrics (OFED)                           │
  │           ibacml / mlx5 / rdma-core / libibverbs               │
  └─────────────────────────────────────────────────────────────────┘
```

### 2.2 MPI 点对点通信

```c
// MPI + RDMA 点对点通信示例
#include <mpi.h>
#include <stdio.h>

int main(int argc, char** argv) {
    MPI_Init(&argc, &argv);

    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    const int N = 1000000;
    double* send_buf = malloc(N * sizeof(double));
    double* recv_buf = malloc(N * sizeof(double));

    // 初始化数据
    for (int i = 0; i < N; i++) {
        send_buf[i] = rank + i * 0.001;
    }

    double t_start = MPI_Wtime();

    if (rank == 0) {
        // MPI_Send 使用 RDMA 传输 (Eager/Rendezvous)
        MPI_Send(send_buf, N, MPI_DOUBLE, 1, 0, MPI_COMM_WORLD);
        printf("Rank 0 sent %d doubles to rank 1\n", N);
    } else if (rank == 1) {
        MPI_Recv(recv_buf, N, MPI_DOUBLE, 0, 0, MPI_COMM_WORLD,
                 MPI_STATUS_IGNORE);
        printf("Rank 1 received %d doubles from rank 0\n", N);
    }

    double t_end = MPI_Wtime();
    if (rank == 0) {
        printf("Transfer time: %.3f ms\n", (t_end - t_start) * 1000);
    }

    MPI_Finalize();
    return 0;
}
```

### 2.3 MPI 集合通信

```c
// MPI AllReduce 集合通信
#include <mpi.h>

void mpi_allreduce_example() {
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    double local_value = rank + 1.0;
    double global_sum = 0.0;

    // 全局求和
    // MPI 内部使用 Ring AllReduce 或 Tree 算法
    // 自动选择最优算法 (基于消息大小和进程数)
    MPI_Allreduce(&local_value, &global_sum, 1, MPI_DOUBLE,
                  MPI_SUM, MPI_COMM_WORLD);

    // global_sum = 1 + 2 + 3 + ... + size = size*(size+1)/2

    printf("Rank %d: global_sum = %.1f\n", rank, global_sum);
}

// MPI Broadcast
void mpi_broadcast_example() {
    int rank;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);

    int root = 0;
    int data[100];

    if (rank == root) {
        // 初始化广播数据
        for (int i = 0; i < 100; i++) {
            data[i] = i * i;
        }
    }

    // 广播到所有进程
    // root 进程的数据被发送到所有其他进程
    MPI_Bcast(data, 100, MPI_INT, root, MPI_COMM_WORLD);
}

// MPI AllGather
void mpi_allgather_example() {
    int rank, size;
    MPI_Comm_rank(MPI_COMM_WORLD, &rank);
    MPI_Comm_size(MPI_COMM_WORLD, &size);

    int local_data = rank * 10;
    int* recv_buffer = malloc(size * sizeof(int));

    // 收集所有进程的数据到每个进程
    MPI_Allgather(&local_data, 1, MPI_INT,
                   recv_buffer, 1, MPI_INT,
                   MPI_COMM_WORLD);

    // recv_buffer = [0, 10, 20, 30, ...]
}
```

---

## 3. OpenFabrics 软件栈

### 3.1 OFED 架构

```
OpenFabrics Alliance / OFED 架构：

  ┌─────────────────────────────────────────────────────────────────┐
  │                    用户空间 (User Space)                         │
  │                                                                  │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐   │
  │  │   MPI       │  │   SHMEM     │  │   Apache Spark/Hadoop   │   │
  │  │ (OpenMPI/  │  │  (OpenSHMEM)│  │   (RDMA加速)            │   │
  │  │  MPICH)    │  │             │  │                         │   │
  │  └──────┬──────┘  └──────┬──────┘  └────────────┬────────────┘   │
  │         │                │                      │                │
  │         └────────────────┼──────────────────────┘                │
  │                          ↓                                         │
  │  ┌─────────────────────────────────────────────────────────────┐ │
  │  │                  Verbs API (libibverbs)                    │ │
  │  │  ibv_post_send / ibv_post_recv / ibv_poll_cq                │ │
  │  └─────────────────────────────────────────────────────────────┘ │
  │                          ↓                                         │
  │  ┌─────────────────────────────────────────────────────────────┐ │
  │  │               RDMA CM (librdmacm)                            │ │
  │  │  rdma_cm_id / rdma_connect / rdma_disconnect               │ │
  │  └─────────────────────────────────────────────────────────────┘ │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                    内核空间 (Kernel)                             │
  │                                                                  │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐   │
  │  │  ib_core   │  │  ib_mad    │  │   ib_uverbs             │   │
  │  │  (IB core) │  │  (管理)    │  │   (字符设备)            │   │
  │  └─────────────┘  └─────────────┘  └─────────────────────────┘   │
  │                                                                  │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐   │
  │  │  mlx5_ib   │  │  hfi1_ib   │  │   qib_ib               │   │
  │  │  (Driver) │  │  (Driver)  │  │   (Driver)             │   │
  │  └─────────────┘  └─────────────┘  └─────────────────────────┘   │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                    硬件 (Hardware)                               │
  │                                                                  │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐   │
  │  │  ConnectX-7│  │  Omni-Path  │  │   InfiniBand Switch     │   │
  │  │  HDR/NDR   │  │  (Intel)    │  │   (QM8700 / SB7890)    │   │
  │  └─────────────┘  └─────────────┘  └─────────────────────────┘   │
  └─────────────────────────────────────────────────────────────────┘
```

### 3.2 Verbs API 与 RDMA 核心

```c
// RDMA Verbs API 编程模型
#include <infiniband/verbs.h>
#include <rdma/rdma_cma.h>

// 1. 获取设备列表
struct ibv_device** dev_list;
struct ibv_context* context;
struct ibv_pd* pd;
struct ibv_cq* cq;
struct ibv_qp* qp;

dev_list = ibv_get_device_list(NULL);
context = ibv_open_device(dev_list[0]);

// 2. 分配保护域
pd = ibv_alloc_pd(context);

// 3. 创建完成队列
cq = ibv_create_cq(context, cq_size, NULL, NULL, 0);

// 4. 创建队列对 (QP)
struct ibv_qp_init_attr qp_init_attr = {
    .send_cq = cq,
    .recv_cq = cq,
    .cap = {
        .max_send_wr = 128,
        .max_recv_wr = 128,
        .max_send_sge = 1,
        .max_recv_sge = 1,
    },
    .qp_type = IBV_QPT_RC,
};

qp = ibv_create_qp(pd, &qp_init_attr);

// 5. 修改 QP 状态 (INIT → RTR → RTS)
struct ibv_qp_attr attr = {
    .qp_state = IBV_QPS_INIT,
    .port_num = 1,
    .pkey_index = 0,
    .qp_access_flags = IBV_ACCESS_REMOTE_READ |
                       IBV_ACCESS_REMOTE_WRITE,
};

ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX |
                          IBV_QP_PORT | IBV_QP_ACCESS_FLAGS);

// 6. 注册内存区域
struct ibv_mr* mr = ibv_reg_mr(pd, buffer, size,
                                IBV_ACCESS_LOCAL_WRITE |
                                IBV_ACCESS_REMOTE_WRITE |
                                IBV_ACCESS_REMOTE_READ);
```

### 3.3 RDMA CM 连接管理

```c
// RDMA Connection Manager (RDMA_CM) 示例
#include <rdma/rdma_cma.h>

// RDMA_CM 事件处理
void* rdma_event_handler(void* arg) {
    struct rdma_cm_id* cm_id = (struct rdma_cm_id*)arg;
    struct rdma_cm_event* event;

    while (rdma_get_cm_event(cm_id->channel, &event) == 0) {
        switch (event->event) {
            case RDMA_CM_EVENT_CONNECT_REQUEST:
                // 处理连接请求
                handle_connect_request(event->id);
                break;

            case RDMA_CM_EVENT_ESTABLISHED:
                // 连接建立完成
                handle_connection_established(event->id);
                break;

            case RDMA_CM_EVENT_DISCONNECTED:
                // 连接断开
                rdma_disconnect(event->id);
                handle_disconnect(event->id);
                break;
        }
        rdma_ack_cm_event(event);
    }
    return NULL;
}

// 建立连接
int create_rdma_connection(struct rdma_cm_id* cm_id,
                           struct sockaddr_in* dst_addr) {
    // 创建 CM ID
    rdma_create_ep(cm_id, NULL, NULL, NULL, RDMA_PS_TCP);

    // 解析地址
    rdma_resolve_addr(cm_id, NULL, (struct sockaddr*)dst_addr, 2000);

    // 等待连接请求
    // ...

    return 0;
}
```

---

## 4. InfiniBand 集群架构

### 4.1 典型 HPC 集群拓扑

```
HPC InfiniBand 集群拓扑 (Fat Tree):

                    ┌─────────────────────────────────────┐
                    │         Core Switch (SB7800)        │
                    │         864 端口 HDR               │
                    └─────────────┬───────────────────────┘
                                  │
        ┌─────────────────────────┼─────────────────────────┐
        │                         │                         │
  ┌─────┴─────┐             ┌─────┴─────┐             ┌─────┴─────┐
  │  Spine 1  │             │  Spine 2  │             │  Spine 3  │
  │ SB8700   │             │ SB8700   │             │ SB8700   │
  └─────┬─────┘             └─────┬─────┘             └─────┬─────┘
        │                         │                         │
  ┌─────┴─────┐             ┌─────┴─────┐             ┌─────┴─────┐
  │  Leaf 1  │             │  Leaf 2  │             │  Leaf N  │
  │ SB7890   │             │ SB7890   │             │ SB7890   │
  └─────┬─────┘             └─────┬─────┘             └─────┬─────┘
        │                         │                         │
  ┌─────┴─────┐             ┌─────┴─────┐             ┌─────┴─────┐
  │  Node 1   │             │  Node 2   │             │  Node N   │
  │ ┌───────┐ │             │ ┌───────┐ │             │ ┌───────┐ │
  │ │GPU/CPU│ │             │ │GPU/CPU│ │             │ │GPU/CPU│ │
  │ └───┬───┘ │             │ └───┬───┘ │             │ └───┬───┘ │
  │     │     │             │     │     │             │     │     │
  │ ┌───┴───┐ │             │ ┌───┴───┐ │             │ ┌───┴───┐ │
  │ │ IB HCA│ │             │ │ IB HCA│ │             │ │ IB HCA│ │
  │ └───────┘ │             │ └───────┘ │             │ └───────┘ │
  └───────────┘             └───────────┘             └───────────┘
```

### 4.2 交换机配置

```bash
# Mellanox OFED 交换机配置 (MLNX-OS)

# 查看交换机信息
show version
show inventory

# 配置 VLAN
vlan 100
  name HPC_NETWORK
  no shutdown

# 配置 IB 子网
show ib switch
show ib fabric

# 配置 QoS
qos
  map dcbx ieee
  set port 1/1 pfc enabled

# 配置 SHARP (如果支持)
sharp
  enable
  show sharp status

# 配置 routing
routing
  enable
  linear-fdb enable
```

### 4.3 节点配置

```bash
# HPC 节点 IB 配置 (RHEL/CentOS)

# 1. 安装 OFED 驱动
yum install -y mlnx-ofa/kernel mlnx-ofa/user

# 2. 加载驱动
/etc/init.d/openibd start

# 3. 配置 IB 设备
cat > /etc/infiniband/openib.conf << 'EOF'
EOF

# 4. 配置 IPoIB (可选，用于管理)
cat > /etc/sysconfig/network-scripts/ifcfg-ib0 << 'EOF'
DEVICE=ib0
TYPE=InfiniBand
BOOTPROTO=static
IPADDR=10.0.1.10
NETMASK=255.255.255.0
ONBOOT=yes
EOF

# 5. 设置 MTU (通常 4092 for IB)
ifconfig ib0 mtu 4092

# 6. 验证
ibstat
ibstatus
ibnetdiscover
```

---

## 5. Lustre 并行文件系统

### 5.1 Lustre 架构

```
Lustre 并行文件系统架构：

  ┌─────────────────────────────────────────────────────────────────┐
  │                    Metadata Server (MDS)                        │
  │  ┌───────────────────────────────────────────────────────────┐  │
  │  │  MDT (Metadata Target)                                    │  │
  │  │  - 文件名、权限、时间戳                                    │  │
  │  │  - 存储在 OST 上的位置                                     │  │
  │  └───────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                    Object Storage Server (OSS)                  │
  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐       │
  │  │     OST 1     │  │     OST 2     │  │     OST N     │       │
  │  │   (Disk/SSD)  │  │   (Disk/SSD)  │  │   (Disk/SSD)  │       │
  │  └───────────────┘  └───────────────┘  └───────────────┘       │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                    Lustre Clients (HPC Nodes)                    │
  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
  │  │   LDISKFS   │  │    LDISKFS  │  │    LDISKFS  │              │
  │  │   / lnet    │  │    / lnet   │  │    / lnet   │              │
  │  └─────────────┘  └─────────────┘  └─────────────┘              │
  └─────────────────────────────────────────────────────────────────┘
                                ↓
  ┌─────────────────────────────────────────────────────────────────┐
  │                    InfiniBand / RDMA Network                     │
  └─────────────────────────────────────────────────────────────────┘

  Lustre + RDMA:
  - LNET (Lustre Networking) 支持 RDMA 传输
  - Lustre v2.12+ 原生 RDMA 支持
  - 吞吐量可达 100+ GB/s (多 OST 并行)
```

### 5.2 Lustre + RDMA 配置

```bash
# Lustre RDMA 配置

# 1. 加载 LNET 模块
modprobe lnet

# 2. 配置 LNET (节点类型)
# MGS/MDS 节点:
lctl net configure

# OSS 节点:
lctl network up
lctl add_nids * tcp 192.168.1.10@tcp

# Client 节点:
lctl network up
lctl import 192.168.1.10@tcp

# 3. 验证 RDMA 传输
lctl dl  # 列出网络接口
lctl ifnum <net>   # 查看接口

# 4. 检查 RDMA 状态
lctl peer_list
lctl route list

# 5. 挂载 Lustre
mount -t lustre 192.168.1.10@tcp0:/lustre /mnt/lustre

# 6. 验证性能
lustre_suite /mnt/lustre  # IO500 基准测试
```

---

## 6. SHARP 集合操作加速

### 6.1 SHARP 原理

```
NVIDIA SHARP (Scalable Hierarchical Aggregation and Reduction Protocol):

传统 AllReduce:
  GPU0 ──→ GPU1 ──→ GPU2 ──→ GPU3 ──→ [All Reduced]
            ↓         ↓         ↓
           Σ        Σ         Σ
  全部需要网络传输

SHARP AllReduce:
  ┌─────────────────────────────────────────────────────────────┐
  │                    InfiniBand Switch                        │
  │                                                              │
  │    GPU0 ──────────────────────────────── [SWITCH] ──→ Σ     │
  │    GPU1 ──────────────────────────────→│                  │
  │    GPU2 ──────────────────────────────→│                   │
  │    GPU3 ─────────────────────────────→│                    │
  │                                       ↓                      │
  │    交换机内部完成归约，结果直接返回给所有 GPU                 │
  └─────────────────────────────────────────────────────────────┘

  优势:
  - 减少 50-90% 网络流量
  - 降低延迟 (交换机硬件归约)
  - 扩展性更好 (O(1) vs O(n))
```

### 6.2 SHARP 配置

```bash
# SHARP 配置 (Mellanox)

# 1. 检查 SHARP 支持
ibv_devinfo -d mlx5_0 | grep sharp
# 期望: sharp_supp_reliable_atomic : 1

# 2. 启用 SHARP
sharpd enable
/etc/init.d/sharpd start

# 3. 配置 SHARP 聚合树
sharp_rack -c 4  # 4 GPU 每组

# 4. NCCL 使用 SHARP
export NCCL_SHARP=1
export NCCL_NET_SHARP=1

# 5. 验证 SHARP
sharpadm sharp族的
sharpadm info
```

---

## 7. HPC 集群性能优化

### 7.1 MPI 调优参数

```bash
# OpenMPI RDMA 调优

# 传输层配置
export OMPI_MCA btl openib,sm,self   # 优先使用 IB
export OMPI_MCA btl_tcp_if_exclude lo,docker0

# 共享内存配置
export OMPI_MCA btl_sm_max_chunk_size 1048576
export OMPI_MCA btl_sm_num_fifos 16

# IB 特定配置
export OMPI_MCA btl_openib_cuda_async_notify false
export OMPI_MCA btl_openib_eager_frag_size 65536
export OMPI_MCA btl_openib_max_recv_quanta 100
export OMPI_MCA btl_openib_max_send_quanta 100

# 集合通信算法
export OMPI_MCA_coll_tuned_use_dynamic_rules=1
export OMPI_MCA_coll_tuned_allreduce_algorithm=3  # Rabenseifner

# 运行时配置
mpirun --mca btl openib,sm,self \
       --mca btl_openib_receive_queues P,65536,64, sumpi_h_bert 512,65536 RDMA,384,64 S,65536,64, sumpi128,65536 RDMA,384,64 S,65536,64 sumpi192,65536 RDMA,384,64 -np 1024 ./hpc_app
```

### 7.2 网络诊断工具

```bash
# IB 网络诊断

# 1. 完整拓扑发现
ibnetdiscover > topology.lst
cat topology.lst

# 2. 子网管理器状态
show_subnet
saquery

# 3. 路径分析
ibtracert <src_lid> <dst_lid>

# 4. 性能计数器
perfquery <lid> <port>

# 5. 链路错误检查
ibcheckerrors

# 6. 带宽延迟测试
ib_write_bw -d mlx5_0 -s 1048576
ib_write_lat -d mlx5_0

# 7. NCCL Tests
./build/all_reduce_perf -b 8 -e 512M -f 2 -g 8
```

---

## 8. 总结

```
HPC RDMA 技术栈：

  应用层:
  ┌─────────────────────────────────────────────────────────────────┐
  │  MPI (OpenMPI/MPICH)  │  OpenSHMEM  │  PGAS (UPC/CAF)          │
  └─────────────────────────────────────────────────────────────────┘
                              ↓
  通信层:
  ┌─────────────────────────────────────────────────────────────────┐
  │  Point-to-Point  │  Collectives  │  RMA (One-sided)           │
  │  (BTL/OB1)       │  (Coll)        │  (MPI_Win)                 │
  └─────────────────────────────────────────────────────────────────┘
                              ↓
  RDMA 层:
  ┌─────────────────────────────────────────────────────────────────┐
  │  Verbs API (libibverbs)  │  RDMA CM (librdmacm)                │
  └─────────────────────────────────────────────────────────────────┘
                              ↓
  驱动层:
  ┌─────────────────────────────────────────────────────────────────┐
  │  mlx5_ib / hfi1 / qib  │  ib_core (kernel)                     │
  └─────────────────────────────────────────────────────────────────┘
                              ↓
  硬件层:
  ┌─────────────────────────────────────────────────────────────────┐
  │  ConnectX-7 / Omni-Path  │  InfiniBand Switch (SHARP)         │
  └─────────────────────────────────────────────────────────────────┘
```

HPC 集群是 RDMA 技术最成熟的应用领域，为 AI 训练集群奠定了技术基础。RDMA 在 HPC 和 AI 领域的成功实践证明，高性能网络是现代分布式计算的核心基础设施。
