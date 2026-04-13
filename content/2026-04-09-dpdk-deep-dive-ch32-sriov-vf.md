---
title: "DPDK 深度探索 ch32：SR-IOV 与 VF"
date: 2026-04-10 11:30:00
tags: [dpdk, sriov, vf, pci, pf, sr-iov, virtual-function, cloud]
description: "深入解析 DPDK SR-IOV：PCIe SR-IOV 机制、VF 管理、虚拟函数分配与云环境应用"
---

# DPDK 深度探索 ch32：SR-IOV 与 VF

> [!abstract] 核心要点
> SR-IOV 让单个物理网卡虚拟出多个 VF 供 VM 使用。本章深入解析 PCIe SR-IOV 机制、VF 生命周期、DPDK VF 驱动与云环境应用。

## 1. SR-IOV 概述

### 1.1 为什么需要 SR-IOV

```
传统 vs SR-IOV：

传统 PCI 分配：
  PF (Physical Function) → 单个 VM
  1 PF = 1 VM

SR-IOV (Single Root I/O Virtualization):
  PF → VF0 → VM1
      → VF1 → VM2
      → VF2 → VM3
      → VF3 → VM4

优势：
  - 1 PF = 多个 VF
  - 硬件级隔离
  - 接近原生性能
  - 共享物理资源
```

### 1.2 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SR-IOV 架构                              │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Physical Function (PF)                   │  │
│  │  - 完全功能的 PCIe 设备                              │  │
│  │  - 管理 VF                                            │  │
│  │  - 资源分配                                           │  │
│  └──────────────────────────────────────────────────────┘  │
│       │       │       │       │                             │
│       ↓       ↓       ↓       ↓                             │
│  ┌────────┬────────┬────────┬────────┐                    │
│  │  VF 0  │  VF 1  │  VF 2  │  VF 3  │  ← 虚拟函数         │
│  │ (轻量) │ (轻量) │ (轻量) │ (轻量) │                    │
│  └────────┴────────┴────────┴────────┘                    │
└─────────────────────────────────────────────────────────────┘
```

## 2. PCIe SR-IOV

### 2.1 PF vs VF

```c
// PCIe 配置空间

// PF - 完全功能
struct pf_config {
    uint16_t vendor_id;
    uint16_t device_id;
    uint16_t control;        // 控制寄存器
    uint16_t status;
    uint32_t bars[6];        // BAR 空间
    // ... 完全功能
};

// VF - 简化功能
struct vf_config {
    uint16_t vendor_id;
    uint16_t device_id;
    uint16_t control;        // 基本控制
    uint32_t bars[6];        // 虚拟 BAR
    uint16_t vf_number;      // VF 编号
    uint32_t vf_migration_state;  // SR-IOV 新增
};
```

### 2.2 SR-IOV 能力

```c
// SR-IOV Capability 结构
struct sriov_capability {
    uint16_t cap_id;         // 0x10
    uint8_t cap_version;     // 版本
    uint8_t next_cap;        // 下一个能力
    uint16_t sriov_cap;      // 控制/状态
    uint32_t sriov_status;   // 状态
    uint16_t num_vfs;        // VF 总数
    uint16_t total_vfs;      // 可分配 VF 数
    uint16_t vf_offset;      // VF 起始
    uint16_t vf_stride;      // VF 间隔
    uint16_t vf_device_id;   // VF 设备 ID
    uint32_t supported_page_sizes;
    uint32_t system_page_size;
};

// 控制寄存器
#define SR_IOV_ENABLE     0x0001  // 启用 SR-IOV
#define SR_IOV_VF_MIGRATION_ENABLE 0x0002  // VF 迁移
#define SR_IOV_VF_ADDRESS_ENABLE   0x0004  // VF 地址
#define SR_IOV_VF_PAGE_SIZE_ENABLE 0x0008  // VF 页大小
```

## 3. VF 生命周期

### 3.1 启用 SR-IOV

```bash
# 查看 NIC 是否支持 SR-IOV
lspci -vvv -d :8086 | grep -i "sr-iov"

# 示例输出：
#   SR-IOV:  + (已支持)
#   VF offset: 16, stride: 1, PFs: 1, VFs: 64

# 查看当前 VF 数量
cat /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs

# 启用 VF
echo 8 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs

# 查看 VF
lspci | grep -i virtual
# 3d:00.1 Ethernet controller: Virtual Function
# 3d:00.2 Ethernet controller: Virtual Function
# ...
```

### 3.2 VF 配置

```bash
# 配置 VF
ip link set eth0 vf 0 mac 00:11:22:33:44:55
ip link set eth0 vf 0 vlan 100
ip link set eth0 vf 0 rate 1000  # 1 Gbps
ip link set eth0 vf 0 spoofchk on
ip link set eth0 vf 0 trust on

# 查看配置
ip link show eth0
# vf 0 MAC: 00:11:22:33:44:55, vlan: 100, spoof checking: ON
# vf 1 MAC: 00:11:22:33:44:56, vlan: 100, spoof checking: ON
```

### 3.3 分配 VF 给 VM

```bash
# QEMU 分配 VF
qemu-system-x86_64 \
    -m 4G \
    -smp 4 \
    -device pci-assign,\
addr=04.0,\
host=3d:00.1

# 或使用 libvirt
# <interface type='hostdev' managed='yes'>
#   <source>
#     <address type='pci' domain='0x0000' bus='0x3d' slot='0x00' function='0x1'/>
#   </source>
# </interface>
```

## 4. DPDK VF 驱动

### 4.1 VF 绑定

```bash
# 查看 PCI 设备
lspci | grep -i ether

# 3d:00.0 Ethernet controller: Physical Function (original)
# 3d:00.1 Ethernet controller: Virtual Function
# 3d:00.2 Ethernet controller: Virtual Function

# 绑定 VF 到 DPDK
dpdk-devbind --bind=vfio-pci 0000:3d:00.1
dpdk-devbind --bind=vfio-pci 0000:3d:00.2

# 查看绑定状态
dpdk-devbind --status

# 示例：
# 0000:3d:00.0 'Ethernet 10Gb' drv=igb_uio unused=
# 0000:3d:00.1 'Virtual Function' drv=vfio-pci unused=
# 0000:3d:00.2 'Virtual Function' drv=vfio-pci unused=
```

### 4.2 VF PMD

```c
// DPDK i40e VF PMD
// 驱动位于 drivers/net/i40e/

#include <rte_ethdev.h>

int
configure_vf(uint16_t port_id)
{
    struct rte_eth_conf conf = {
        .rxmode = {
            .mq_mode = ETH_MQ_RX_VMDQ_RSS,
            .split_hdr_size = 0,
        },
        .txmode = {
            .mq_mode = ETH_MQ_TX_VMDQ,
        },
    };

    // 配置
    rte_eth_dev_configure(port_id, 1, 1, &conf);

    // 设置 VF MAC
    struct ether_addr mac = {
        .addr_bytes = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55}
    };
    rte_eth_dev_default_mac_set(port_id, &mac);

    // 设置 VF VLAN
    rte_eth_dev_set_vlan_filter(port_id, 100, 1);

    return 0;
}
```

### 4.3 VF 特性

```c
// VF 支持的特性
struct vf_feature {
    // 网络
    uint64_t rss;
    uint64_t tcp_lro;
    uint64_t vlan_filter;
    uint64_t vlan_strip;

    // TSO
    uint64_t tso;
    uint64_t tso_ipv6;

    // checksum
    uint64_t rx_csum;
    uint64_t tx_csum_ip;
    uint64_t tx_csum_tcp;
    uint64_t tx_csum_udp;

    // RDMA (部分 VF)
    uint64_t rdma;
};

// 查询 VF 能力
uint64_t
get_vf_capabilities(uint16_t port_id)
{
    struct rte_eth_dev_info dev_info;
    rte_eth_dev_info_get(port_id, &dev_info);
    return dev_info.flow_type_rss_offloads;
}
```

## 5. 云环境 VF

### 5.1 AWS ENA

```bash
# AWS 使用 ENA (不是 SR-IOV)
# 但新实例支持 ENA Express (SR-IOV)

# 检查 ENA 版本
ethtool -i eth0

# 示例：
# driver: ena
# version: 2.8.0
# firmware-version:
# supports-statistics: yes
# supports-test: yes
# supports-priv-flags: yes
```

### 5.2 Azure

```bash
# Azure 使用 Mellanox SR-IOV
# Standard_D32s_v3 支持

# 检查 Mellanox 设备
lspci | grep -i mellanox
# 03:00.0 Ethernet controller: Mellanox Technologies MT28800

# 启用 VF
echo 4 > /sys/class/net/eth0/device/sriov_numvfs

# Azure 特定配置
# VF 必须设置为 trust=on 才能使用
ip link set eth0 vf 0 trust on
```

### 5.3 GCP

```bash
# GCP gVNIC 使用 VirtIO，不是传统 SR-IOV
# 但底层网络是 Jupiter fabric

# 查看 gVNIC
lspci | grep -i google
# 00:04.0 Ethernet controller: Google Virtio network
```

## 6. VF 性能

### 6.1 性能对比

| 方案 | 吞吐量 | 延迟 | CPU 开销 |
|------|--------|------|----------|
| **virtio-net** | ~5-10 Gbps | ~20μs | 中 |
| **VF (SR-IOV)** | ~15-20 Gbps | ~5-10μs | 低 |
| **物理网卡** | ~40-100 Gbps | ~1-2μs | 极低 |

### 6.2 VF 优化

```c
// VF RX 优化
static uint16_t
vf_recv_burst(void *rxq, struct rte_mbuf **rx_pkts, uint16_t nb_pkts)
{
    struct i40e_rx_queue *q = rxq;

    // 使用批量 DMA
    uint16_t nb = rte_eth_rx_burst(q->port_id, q->queue_id,
                                   rx_pkts, nb_pkts);

    // 启用 LRO
    if (q->lro_enabled) {
        process_lro(rx_pkts, nb);
    }

    return nb;
}
```

## 7. 安全考虑

### 7.1 VF 安全

```bash
# 启用 MAC 地址检查
ip link set eth0 vf 0 mac 00:11:22:33:44:55
ip link set eth0 vf 0 spoofchk on

# 启用 VLAN 检查
ip link set eth0 vf 0 vlan 100
ip link set eth0 vf 0 vlan stripped on

# 速率限制
ip link set eth0 vf 0 rate 1000  # 1 Gbps

# Trust 模式（谨慎使用）
ip link set eth0 vf 0 trust off  # 默认
# trust on: VF 可以发送任何流量
```

### 7.2 VF 隔离

```c
// VF 隔离配置
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

// PF 配置
struct rte_eth_pf_conf pf_conf = {
    .switch_domain_id = 0,
    .pf_token = 0,
};

// 设置 switch domain
rte_eth_dev_switch_esw_mode(port_id, RTE_ETH_DEV_SWITCH_DOMAIN_ID);
```

## 8. 总结

SR-IOV 架构：

```
┌─────────────────────────────────────────────────────────────┐
│                    SR-IOV 路径                             │
│                                                              │
│  Physical NIC                                               │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  PF (管理)                                          │  │
│  │  ├─ VF 0 ──── VM1                                 │  │
│  │  ├─ VF 1 ──── VM2                                 │  │
│  │  └─ VF 2 ──── VM3                                 │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

VF vs virtio：

| 特性 | VF (SR-IOV) | virtio |
|------|-------------|--------|
| **性能** | 极高 | 高 |
| **兼容性** | 需要硬件 | 广泛支持 |
| **隔离** | 硬件级 | 软件级 |
| **动态分配** | 受限于 VF 数 | 灵活 |
| **云支持** | 部分云 | 全部云 |

---

## 参考资源

- [PCI-SIG SR-IOV](https://pcisig.com/sriov)
- [DPDK SR-IOV](https://doc.dpdn.org/guides/nics/intel_i40e.html)
- [Linux SR-IOV](https://www.kernel.org/doc/html/latest/networking/sriov.html)
