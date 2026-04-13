---
title: "DPDK 第三十五章：SR-IOV 与 VF 管理机制"
date: 2026-04-09 16:00:00
tags: [dpdk, sr-iov, virtualization, pci, vf, networking]
description: "深入解析 SR-IOV 技术原理、VF/PF 管理机制、DPDK 中的 SR-IOV 支持与性能优化"
---

# DPDK 第三十五章：SR-IOV 与 VF 管理机制

> [!abstract] 核心要点
> SR-IOV（Single Root I/O Virtualization）允许物理网卡虚拟出多个 VF（Virtual Function），让虚拟机直接访问硬件。本章解析 SR-IOV 架构、VF 管理、DPDK 支持与常见配置问题。

## 1. SR-IOV 概述

### 1.1 传统 vs SR-IOV

**传统虚拟化网络路径**：
```
VM App → Virtio Driver → QEMU → vhost-net → TAP → Linux Bridge → Physical NIC → Wire
         (软件模拟)        (内核)    (内核)    (内核)
```

**SR-IOV 路径**：
```
VM App → Virtio Driver → Virtual Function (VF) → Physical NIC → Wire
         (半虚拟化)           (硬件直通)       (硬件)
```

### 1.2 核心概念

| 概念 | 说明 |
|------|------|
| **PF (Physical Function)** | 物理网卡的完整功能，宿主机使用 |
| **VF (Virtual Function)** | PF 虚拟出的轻量级功能，分配给 VM |
| **SR-IOV** | 标准，允许硬件虚拟化 |
| **ARI** | Alternative Routing ID，提高 VF 扩展性 |

### 1.3 性能优势

- **低延迟**：VM 直接访问网卡，无 vhost-net 软件中转
- **高吞吐**：绕过 Linux 内核网络栈
- **低 CPU 开销**：减少虚拟化税
- **确定性**：避免内核调度抖动

## 2. 硬件架构

### 2.1 PCIe 架构

```
┌─────────────────────────────────────────────────────────┐
│                    Physical NIC (PF)                     │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Physical Function                    │  │
│  │  - 完整驱动栈                                     │  │
│  │  - 所有硬件资源                                   │  │
│  │  - 管理控制平面                                   │  │
│  └──────────────────────────────────────────────────┘  │
│                                                          │
│  ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐    │
│  │ VF0│ │ VF1│ │ VF2│ │ VF3│ │ VF4│ │ VF5│ │ VF6│ ...│
│  └────┘ └────┘ └────┘ └────┘ └────┘ └────┘ └────┘    │
└─────────────────────────────────────────────────────────┘
       │       │       │       │       │       │       │
       ▼       ▼       ▼       ▼       ▼       ▼       ▼
    ┌────┐ ┌────┐ ┌────┐ ┌────┐
    │ VM1│ │ VM2│ │ VM3│ │ VM4│  ...
    └────┘ └────┘ └────┘ └────┘
```

### 2.2 VF 资源

每个 VF 独立拥有：
- ** PCIe 配置空间**
- ** BAR (Base Address Register) 映射**
- ** DMA 引擎**
- ** 队列对（Rx/Tx Queue Pair）**
- ** RX 过滤器表**

### 2.3 硬件支持

主流网卡 SR-IOV 支持：

| 厂商 | 型号 | 最大 VF 数 | 驱动 |
|------|------|------------|------|
| Intel | X710 | 64 | i40e |
| Intel | XL710 | 64 | i40e |
| Intel | XXV710 | 64 | i40e |
| Intel | E810 | 256 | ice |
| Broadcom | NetXtreme | 128 | bnxt_en |
| NVIDIA | ConnectX | 128 | mlx5_core |

## 3. Linux 配置

### 3.1 检查 SR-IOV 支持

```bash
# 1. 检查网卡是否支持 SR-IOV
lspci -vv -s 0000:3d:00.0 | grep -i "sr-iov\|Virtual"

# 输出示例：
# Capabilities: [160] Single Root I/O Virtualization (SR-IOV)
#     IOVCap:     Migration-, InterruptMessageNumber: 0
#     IOVCtl:     Enable- Disable- Migration- INT- 
#     IOVSta:     Migration- 
#     VFs:     64 max, 64 current

# 2. 查看当前 VF 数量
cat /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs
# 0

# 3. 查看网卡驱动
ethtool -i eth0
# driver: i40e
```

### 3.2 启用 SR-IOV

```bash
# 方法 1：临时启用
# 启用 8 个 VF
echo 8 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs

# 验证
ls /sys/bus/pci/devices/0000:3d:00.0/virtfn*
# virtfn0  virtfn1  virtfn2 ... virtfn7

# 查看 VF 的 PCI 地址
ls -l /sys/bus/pci/devices/0000:3d:00.0/virtfn0
# -> ../0000:3d:02.0

# 方法 2：永久配置（通过 udev 或 grub）

# udev 规则 /etc/udev/rules.d/100-sriov.rules
ACTION=="add", SUBSYSTEM=="pci", DRIVER=="i40e", \
    ATTR{sriov_numvfs}="8"
```

### 3.3 配置 VF MAC 地址

```bash
# 为 VF 设置 MAC（需要在 PF 驱动中启用）
ip link set eth0 vf 0 mac 00:11:22:33:44:55
ip link set eth0 vf 1 mac 00:11:22:33:44:56

# 查看 VF 配置
ip link show eth0
# eth0: <BROADCAST,MULTICAST,UP,LOWER_UP>
#     vf 0 MAC 00:11:22:33:44:55, vlan 100, spoof checking on
#     vf 1 MAC 00:11:22:33:44:56, vlan 100, spoof checking on
```

### 3.4 VF VLAN 配置

```bash
# 设置 VLAN
ip link set eth0 vf 0 vlan 100

# 启用 VLAN 过滤
ip link set eth0 vf 0 vlan 100, qos 3

# 禁用 VLAN
ip link set eth0 vf 0 vlan 0
```

### 3.5 启用/禁用 VF

```bash
# 禁用 VF
echo 0 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs

# 重新配置 VF 数量
echo 16 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs
```

## 4. VF 绑定到 DPDK

### 4.1 解除 VF 驱动绑定

```bash
# 查看 VF 当前驱动
lspci -k -s 0000:3d:02.0
# 0000:3d:02.0:vf-pci
#         kernel driver in use: vfio-pci

# 重新绑定到 igb_uio 或 vfio-pci
sudo dpdk-devbind.py -u 0000:3d:02.0  # 解绑
sudo dpdk-devbind.py -b igb_uio 0000:3d:02.0  # 绑定到 igb_uio
# 或
sudo dpdk-devbind.py -b vfio-pci 0000:3d:02.0  # 绑定到 vfio-pci
```

### 4.2 批量绑定脚本

```bash
#!/bin/bash
# setup_sr-iov.sh

PF="0000:3d:00.0"
NUM_VFS=8

# 启用 VF
echo $NUM_VFS > /sys/bus/pci/devices/$PF/sriov_numvfs

# 等待 VF 创建
sleep 2

# 获取所有 VF PCI 地址
VFS=$(ls /sys/bus/pci/devices/$PF/virtfn* | xargs -I{} basename {})

for VF in $VFS; do
    # 解绑当前驱动
    sudo dpdk-devbind.py -u $VF
    
    # 绑定到 vfio-pci（推荐）
    sudo dpdk-devbind.py -b vfio-pci $VF
    
    echo "Bound $VF to vfio-pci"
done

# 显示绑定状态
sudo dpdk-devbind.py --status
```

## 5. DPDK 中的 SR-IOV

### 5.1 EAL 参数

```bash
# 基础启动
sudo ./myapp -l 0,1,2,3 -n 4 -- \
    -w 0000:3d:02.0 \       # 指定 VF PCI
    -w 0000:3d:02.1

# 同时使用 PF 和 VF
sudo ./myapp -l 0,1 -n 4 -- \
    -w 0000:3d:00.0 \       # PF
    -w 0000:3d:02.0 \       # VF1
    -w 0000:3d:02.1         # VF2

# 指定 VF Token（当 PF 和 VF 属于不同的 VF_TOKEN 时）
# 通常在 MacVTap 或 SR-IOV 设备需要
```

### 5.2 VF 端口发现

```c
#include <rte_ethdev.h>

// DPDK 启动后枚举所有端口
uint16_t port_count = rte_eth_dev_count_avail();
printf("Available ports: %u\n", port_count);

// 检查每个端口的 PCI 信息
for (uint16_t port_id = 0; port_id < port_count; port_id++) {
    struct rte_eth_dev_info dev_info;
    rte_eth_dev_info_get(port_id, &dev_info);
    
    printf("Port %u: %s\n", port_id, dev_info.device->name);
    printf("  PCI: %04x:%02x:%02x.%02x\n",
           dev_info.pci_dev->addr.domain,
           dev_info.pci_dev->addr.bus,
           dev_info.pci_dev->addr.devid,
           dev_info.pci_dev->addr.function);
    
    // 检查是否为 VF
    if (dev_info.pci_dev->hdr_type == RTE_PCI_KDRV_VFIO_PCI) {
        printf("  Type: Virtual Function\n");
    }
}
```

### 5.3 VF 流量配置

```c
// 设置 VF MAC 地址
int set_vf_mac(uint16_t port_id, int vf, struct rte_ether_addr *mac) {
    return rte_eth_dev_set_vf_mac_addr(port_id, vf, mac);
}

// 设置 VF VLAN
int set_vf_vlan(uint16_t port_id, int vf, uint16_t vlan_id) {
    return rte_eth_dev_set_vf_vlan(port_id, vf, vlan_id);
}

// 启用/禁用 VF 混杂模式
int set_vf_promisc(uint16_t port_id, int vf, int enable) {
    return rte_eth_dev_set_vf_mac_addr_filter(port_id, vf, enable);
}
```

### 5.4 VF 与 Virtio 的协同

```
┌──────────────────────────────────────────────────────────────┐
│                         VM                                   │
│  ┌────────────┐                                              │
│  │ Virtio Driver │ (前端驱动)                                 │
│  └──────┬─────┘                                              │
│         │ virtqueue (shared memory)                          │
└─────────┼────────────────────────────────────────────────────┘
          │
┌─────────▼────────────────────────────────────────────────────┐
│                         VF (DPDK)                             │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              Virtio Frontend (Virtio PMD)                │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
          │
┌─────────▼────────────────────────────────────────────────────┐
│                    Physical NIC                               │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │              Virtio Backend (SR-IOV)                      │ │
│  └──────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

## 6. 性能调优

### 6.1 VF 队列配置

```c
// 配置 VF 的队列数
struct rte_eth_conf port_conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_NONE,
    },
};

// 每个 VF 独立配置队列数
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

printf("Max Rx queues: %u\n", dev_info.max_rx_queues);
printf("Max Tx queues: %u\n", dev_info.max_tx_queues);

// 建议：根据 VM CPU 核数配置队列
uint16_t num_queues = rte_lcore_count();
```

### 6.2 避免 VF 间干扰

```bash
# 将 VF 绑定到特定 NUMA 节点
echo 2 > /sys/bus/pci/devices/0000:3d:02.0/numa_node

# 在相同 NUMA 节点上启动 DPDK 应用
sudo ./myapp -l 0,1,2,3 -n 4 \
    --socket-mem 1024,0 \  # 只分配 local memory
    -w 0000:3d:02.0
```

### 6.3 启用 Flow Director

```c
// 在 PF 上启用 Flow Director，将特定流导向特定 VF
struct rte_eth_fdir_conf fdir_conf = {
    .mode = RTE_FDIR_MODE_PERFECT,
    .pballoc = RTE_FDIR_PBALLOC_64K,
    .status = RTE_FDIR_REPORT_STATUS,
};

rte_eth_dev_fdir_set_conf(port_id, &fdir_conf);

// 添加 Flow Director 规则
struct rte_eth_fdir_filter filter = {
    .l4_type = RTE_FDIR_L4YPE_TCP,
    .ip_spec.src.ip = RTE_IPV4(192, 168, 1, 0),
    .ip_spec.mask.src.ip = RTE_IPV4(255, 255, 255, 0),
    .flex_conf.flex_mask = {...},
};
```

## 7. 常见问题

### 7.1 VF 无法启用

```bash
# 检查 BIOS 设置
# 确保 "SR-IOV" 已启用

# 检查内核支持
grep -i sriov /boot/config-$(uname -r)
# CONFIG_SRIOV=y

# 驱动是否支持
modinfo i40e | grep sriov
# parm:       SRIOV: number of Virtual Functions to enable (int)
```

### 7.2 VF 无法分配给 VM

```bash
# libvirt 配置示例
<interface type='hostdev'>
  <source>
    <address type='pci' domain='0x0000' bus='0x3d' slot='0x02' function='0x0'/>
  </source>
  <mac address='00:11:22:33:44:55'/>
  <vlan>
    <tag id='100'/>
  </vlan>
</interface>

# 确保 VF 没有绑定到 vfio-pci
# libvirt 需要使用 pci-stub 或 vfio-pci
```

### 7.3 VF 通信问题

```bash
# 检查 VF 是否 up
ip link show

# 确保 PF 驱动启用了 switchdev 或允许 VF 间通信
# Intel i40e: 查看 switchdev 模式
cat /sys/class/net/eth0/sriov/switchdev

# 如果需要 VF 间通信，可能需要配置 MAC VLAN 或 bridge
```

## 8. 总结

SR-IOV 是 DPDK 虚拟化场景的关键技术：

1. **PF/VF 分离**：PF 管理控制平面，VF 用于数据平面
2. **硬件直通**：绕过软件虚拟化层，实现接近原生性能
3. **配置复杂**：需要在 BIOS、Linux、DPDK 多个层面配置
4. **安全考虑**：启用 MAC spoofing 检查、VLAN 过滤

---

## 参考资源

- [SR-IOV 官方文档](https://doc.dpdk.org/guides/linux_gsg/linux_drivers_kni.html#single-root-io-virtualization-sr-iov)
- [Intel SR-IOV 配置指南](https://www.intel.com/content/www/us/en/docs/network-fiabric/configuration-guide/)
