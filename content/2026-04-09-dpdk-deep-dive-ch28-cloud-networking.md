---
title: "DPDK 深度探索 ch28：云环境网络"
date: 2026-04-10 09:30:00
tags: [dpdk, cloud, aws, azure, gcp, nitro, vhost, ena, virtio]
description: "深入解析 DPDK 云环境网络：AWS ENA、Virtio-Net、Azure Accelerated Networking、Hypervisor 加速"
---

# DPDK 深度探索 ch28：云环境网络

> [!abstract] 核心要点
> 云环境提供虚拟化网络能力。本章深入解析 AWS ENA、Azure Accelerated Networking、Google Virtio-Net 等云网络虚拟化技术。

## 1. 云网络概述

### 1.1 云网络架构

```
┌─────────────────────────────────────────────────────────────┐
│                    云环境网络架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               Virtual Machine                          │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  Virtio Driver (半虚拟化)                     │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               Hypervisor (Xen/KVM)                    │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │ ENA     │  │  VF     │  │ vhost   │          │  │
│  │  │ (AWS)  │  │(Azure) │  │(GCP)   │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               Physical NIC + Switch                   │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 主要云提供商对比

| 提供商    | 接口      | 驱动  | 最大带宽 | 最大 PPS |
| --------- | --------- | ----- | -------- | -------- |
| **AWS**   | ENA       | ena   | 100 Gbps | 100M     |
| **Azure** | SR-IOV VF | mlx5  | 50 Gbps  | 50M      |
| **GCP**   | gVNIC     | gvnic | 50 Gbps  | 50M      |

## 2. AWS ENA

### 2.1 ENA 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    AWS ENA 架构                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              EC2 Instance                             │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  ENA Driver (Linux kernel)                    │   │  │
│  │  │                                               │   │  │
│  │  │  TX: sk_buff → ENA Queue → Doorbell         │   │  │
│  │  │  RX: ENA Queue → sk_buff → NIC             │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              AWS Nitro Hypervisor                      │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  ENA Backend (vhost-user style)             │   │  │
│  │  │  - 共享内存队列                              │   │  │
│  │  │  - Doorbell 通知                            │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Nitro NIC (Custom ASIC)                 │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 ENA 特性

```
ENA (Elastic Network Adapter) 特性：

1. 高带宽
   - c5.metal: 100 Gbps
   - c5.18xlarge: 25 Gbps

2. 低延迟
   - 硬件卸载
   - 跳过 hypervisor

3. 高级特性
   - TCP/UDP checksum offload
   - TSO/LRO (TCP Segmentation/Receive Offload)
   - RSS (Receive Side Scaling)
   - VXLAN offload

4. 多队列
   - 支持最多 16 个 TX/RX 队列
   - 队列大小可配置
```

### 2.3 ENA 驱动

```c
// Linux ENA driver (ena_netdev.c)
struct ena_adapter {
    // 设备信息
    struct ena_dev *ena_dev;
    u16 device_id;

    // 队列
    struct ena_ring *tx_ring;
    struct ena_ring *rx_ring;
    int num_queues;

    // 统计
    u64 tx_packets;
    u64 rx_packets;
};

// TX 路径
static netdev_tx_t
ena_start_xmit(struct sk_buff *skb, struct net_device *netdev)
{
    struct ena_adapter *adapter = netdev_priv(netdev);
    struct ena_ring *ring = &adapter->tx_ring[skb->queue_mapping];

    // 获取 TX descriptor
    struct ena_tx_ctx ctx = {
        .skb = skb,
        .header_len = skb->len,
    };

    // 填充 descriptor
    ena_prep_tx(skb, &ctx);

    // 获取 buffer
    u16 next_to_use = ring->next_to_use;
    struct ena_tx_buffer *txb = &ring->tx_buffer[next_to_use];

    // DMA 映射
    dma_addr_t dma = dma_map_single(&adapter->pdev->dev,
                                     skb->data, skb->len, DMA_TO_DEVICE);

    txb->dma = dma;
    txb->len = skb->len;

    // 写入 descriptor
    ring->tx_desc[next_to_use] = (struct ena_tx_desc) {
        .buffer_addr = dma,
        .length = skb->len,
        .req_id = next_to_use,
    };

    // doorbell
    writel(next_to_use + 1, ring->db_addr);

    return NETDEV_TX_OK;
}
```

## 3. Azure Accelerated Networking

### 3.1 Azure 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Azure 架构                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VM (Linux/Windows)                        │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  Mellanox VF Driver (mlx5)                    │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓ SR-IOV                         │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Azure Hypervisor (Hyper-V)                 │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  VF Switch (Synthetic path backup)           │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Azure Portal Network (SmartNIC)          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Mellanox VF

```c
// Azure VM 使用 Mellanox ConnectX 系列
// 驱动: mlx5 (RDMA_CM +verbs)

// 初始化
static int
mlx5_device_init(struct mlx5_priv *priv)
{
    // 获取 VF 能力
    struct mlx5_hca_cap *hca_cap = &priv->hca_cap;

    // 启用 DPDK 模式
    mlx5_set_dpad(priv);

    // 配置队列
    priv->rxqs = mlx5_alloc_rx_queues(priv, priv->config.nqs);
    priv->txqs = mlx5_alloc_tx_queues(priv, priv->config.nqs);

    return 0;
}
```

### 3.3 Azure 特性

```
Azure Accelerated Networking:

1. SR-IOV
   - Mellanox ConnectX-4/5
   - VF 直接分配给 VM

2. 性能
   - 最高 50 Gbps
   - 延迟 ~10μs

3. RDMA
   - 支持 RoCE v2
   - Azure HPC

4. 限制
   - 需要特定实例类型
   - 不能动态修改
```

## 4. Google gVNIC

### 4.1 gVNIC 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Google gVNIC 架构                       │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              GCE Instance                             │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  gVNIC Driver (gvnic)                         │   │  │
│  │  │  - PCIe BAR 访问                              │   │  │
│  │  │  - Doorbell 机制                              │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Titan Hypervisor                         │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Jupiter Fabric (Google 内部网络)         │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 gVNIC 特性

```
Google Virtual NIC (gVNIC):

1. Virtio-blk / Virtio-net 兼容
   - 使用 Google 自定义 Virtio 实现

2. 性能
   - 最高 50 Gbps
   - 50M PPS

3. 安全
   - Always encrypted
   - Titan 安全芯片

4. 特性
   - Packet Mirroring
   - Network Telemetry
   - VPC 集成
```

## 5. 云网络 DPDK 支持

### 5.1 云环境 DPDK

```bash
# 在云环境使用 DPDK
# 1. 检查 PCI 设备
lspci | grep -i ethernet

# AWS:
# 00:1e.0 Ethernet controller: Amazon.com, Inc. ENA

# Azure:
# 00:04.0 Ethernet controller: Mellanox Technologies

# GCP:
# 00:04.0 Ethernet controller: Google, Inc. Virtio network

# 2. 绑定到 DPDK
dpdk-devbind --bind=vfio-pci 00:1e.0
```

### 5.2 云 PMD

```c
// 云环境 DPDK PMD

// AWS ENA PMD
// drivers/net/ena/ena.h

struct ena_stats {
    u64 tx_packets;
    u64 tx_bytes;
    u64 rx_packets;
    u64 rx_bytes;
    u64 tx_drops;
    u64 rx_drops;
};

// Azure mlx5 PMD
// drivers/net/mlx5/mlx5.h

struct mlx5_stats {
    u64 ipackets;
    u64 opackets;
    u64 ibytes;
    u64 obytes;
    u64 idropped;
    u64 odropped;
};
```

### 5.3 云网络配置

```bash
# AWS ENA 配置
ethtool -E eth0 magic 0x1d0f0000 offset 0x70 value 0x180

# Azure 启用 SR-IOV
az vm update --name myVM --set networkProfile.networkInterfaces[0].enableAcceleratedNetworking=true

# GCP 配置
gcloud compute instances create my-instance \
    --network-interface=subnet=my-subnet \
    --image-family=cos-stable \
    --image-project=cos-cloud
```

## 6. 跨云网络

### 6.1 DPDK 跨云方案

```
DPDK 应用可在多个云环境运行：

┌─────────────────────────────────────────────────────────────┐
│                    DPDK 跨云                                 │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK Application                         │  │
│  │                                                       │  │
│  │  ┌──────────────────────────────────────────────┐   │  │
│  │  │  rte_eth_rx_burst() / tx_burst()              │   │  │
│  │  └──────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────┘  │
│            ↓              ↓              ↓                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐            │
│  │ AWS ENA  │    │Azure VF │    │GCP gVNIC │            │
│  └──────────┘    └──────────┘    └──────────┘            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 虚拟交换机

```bash
# OVS-DPDK 跨云
# 在每个云实例运行 OVS-DPDK

# AWS:
ovs-vsctl add-br br0
ovs-vsctl add-port br0 eth0

# Azure:
ovs-vsctl add-br br0
ovs-vsctl add-port br0 eth0

# GCP:
ovs-vsctl add-br br0
ovs-vsctl add-port br0 eth0
```

## 7. 总结

云网络技术对比：

| 云        | 接口   | 驱动  | 卸载 | RDMA |
| --------- | ------ | ----- | ---- | ---- |
| **AWS**   | ENA    | ena   | Yes  | EFA  |
| **Azure** | SR-IOV | mlx5  | Yes  | Yes  |
| **GCP**   | gVNIC  | gvnic | Yes  | No   |

云网络优化：

```
1. 选择合适实例类型 (HPC/C5/C6i)
2. 启用加速网络
3. 使用 DPDK
4. 多队列 RSS
5. 大页内存
```

---

## 参考资源

- [AWS ENA](https://github.com/amzn/amzn-drivers)
- [Azure Accelerated Networking](https://learn.microsoft.com/en-us/azure/virtual-network/create-vm-accelerated-networking-cli)
- [Google gVNIC](https://cloud.google.com/compute/docs/networking/using-gvnic)
