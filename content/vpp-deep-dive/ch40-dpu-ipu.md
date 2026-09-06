---
title: "VPP 深入探讨 ch40：DPU/IPU 集成"
date: 2026-04-16 11:30:00
tags: [vpp, dpu, ipu, smartnic, doca, bluefield, stingray, 卸载, offload]
description: "深入解析 VPP 与 DPU/IPU 集成：SmartNIC 架构、DOCA 框架、BlueField/融噶青-Stingray、VPP 卸载路径、以及主机管理"
---

# VPP 深入探讨 ch40：DPU/IPU 集成

> [!abstract] 核心要点
> DPU (Data Processing Unit) 和 IPU (Infrastructure Processing Unit) 是下一代智能网卡的核心。本章详解 VPP 与 DPU/IPU 的集成架构：NVIDIA DOCA、Intel IPU、Broadcom Stingray、以及 VPP 卸载路径。

## 1. DPU/IPU 概述

### 1.1 什么是 DPU/IPU？

```
┌─────────────────────────────────────────────────────────────┐
│                    DPU vs IPU 定义                          │
│                                                              │
│  DPU (Data Processing Unit):                               │
│  - NVIDIA 命名                                              │
│  - 聚焦数据平面加速                                         │
│  - BlueField 系列                                          │
│                                                              │
│  IPU (Infrastructure Processing Unit):                     │
│  - Intel 命名                                               │
│  - 聚焦基础设施处理                                         │
│  - Mount Evans 系列                                        │
│                                                              │
│  共同目标:                                                  │
│  - 卸载主机网络/存储/安全                                  │
│  - 释放 CPU 资源                                           │
│  - 隔离租户流量                                            │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 SmartNIC 演进

```
┌─────────────────────────────────────────────────────────────┐
│                    SmartNIC 演进                           │
│                                                              │
│  Gen 1: 简单 NIC                                             │
│  ┌─────────┐                                                 │
│  │   NIC   │  - 基础收发                                    │
│  │ (DPDK)  │  - 驱动卸载                                    │
│  └─────────┘                                                │
│                                                              │
│  Gen 2: 智能 NIC                                             │
│  ┌─────────┐ ┌─────────┐                                   │
│  │   NIC   │ │   ARM   │  - 简单卸载                        │
│  │         │ │ Process │  - 协议栈卸载                      │
│  └─────────┘ └─────────┘                                   │
│                                                              │
│  Gen 3: DPU/IPU                                              │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐                      │
│  │   NIC   │ │   ARM   │ │   GPU   │  - 完全卸载           │
│  │ (DMA)   │ │  Cores  │ │(optional)│ - 硬件加速           │
│  └─────────┘ └─────────┘ └─────────┘  - 隔离环境            │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 DPU 核心功能

|                | 功能            | 说明    | 卸载收益 |
| -------------- | --------------- | ------- | -------- |
| **网络虚拟化** | SR-IOV, VirtIO  | 20% CPU |
| **存储**       | NVMe-oF, vhost  | 30% CPU |
| **安全**       | IPSec, TLS      | 40% CPU |
| **网络协议**   | TCP/IP, RDMA    | 50% CPU |
| **编排**       | OVS, Kubernetes | 30% CPU |

## 2. NVIDIA DOCA 框架

### 2.1 DOCA 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    NVIDIA DOCA 架构                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Host (DPU)                         │   │
│  │                                                       │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │   │
│  │  │  DPU    │  │  DOCA   │  │  RDMA    │            │   │
│  │  │ Drivers │  │  Runtime │  │  Verbs   │            │   │
│  │  └─────────┘  └─────────┘  └─────────┘            │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │              DOCA Services                    │    │   │
│  │  │  - DPDK (VPP)                               │    │   │
│  │  │  - Storage                                  │    │   │
│  │  │  - Security                                 │    │   │
│  │  │  - AI/ML                                    │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    BlueField Hardware                │   │
│  │                                                       │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐            │   │
│  │  │  ConnectX  │ │   ARM   │  │   e-switch  │        │   │
│  │  │  InfiniBand │ │  Cores  │  │  (ASIC)    │         │   │
│  │  └─────────┘  └─────────┘  └─────────┘            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 DOCA 组件

```bash
# DOCA 核心组件

# 1. DOCA Comm Net (网络)
doca_net:
  - RDMA/RoCE
  - DOCA Flow
  - OVS offload

# 2. DOCA Storage (存储)
doca-storage:
  - NVMe-oF target/initiator
  - blobfs
  - AI storage

# 3. DOCA Security (安全)
doca-security:
  - IPsec/TLS crypto
  -正则表达式 (RegEx)
  - DPI

# 4. DOCA GPUNetIO (GPU)
doca-gpu:
  - GPUDirect RDMA
  - cuPy加速
```

### 2.3 DOCA Flow

```c
// doca_flow 示例 - VPP 卸载路径

#include <doca_flow.h>

/* 创建 DOCA Flow 管道 */
struct doca_flow_pipe *create_udp_pipe(struct doca_flow_port *port)
{
    struct doca_flow_match match = {
        .out_src_ip = TRUE,
        .l4_type = DOCA_FLOW_L4_TYPE_UDP,
    };

    struct doca_flow_actions actions = {
        . decap = TRUE,  // 卸载 VXLAN 解封装
    };

    struct doca_flow_pipe_cfg cfg = {
        .name = "vpp_offload",
        .match = &match,
        .actions = &actions,
        .port = port,
    };

    return doca_flow_create_pipe(&cfg);
}

/* 添加匹配规则 */
int add_vpp_offload_rule(struct doca_flow_pipe *pipe)
{
    struct doca_flow_match match = {
        .out_src_ip = TRUE,
        .src_port = 4789,  // VXLAN 端口
    };

    struct doca_flow_fwd fwd = {
        . type = DOCA_FLOW_FWD_VPP,  // 重定向到 VPP
    };

    return doca_flow_pipe_add_entry(pipe, &match, &fwd);
}
```

## 3. BlueField 集成

### 3.1 BlueField 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    BlueField 3 架构                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Host CPU                          │   │
│  │   - VMs/Containers                                 │   │
│  │   - VPP (数据平面)                                  │   │
│  │   - VirtIO/SR-IOV                                 │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ PCIe                            │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              BlueField 3 DPU                         │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           ConnectX-7 (400GbE)                │    │   │
│  │  │  - DMA 引擎                                    │    │   │
│  │  │  - RDMA/RoCE                                  │    │   │
│  │  │  -crypto (IPSec/TLS)                         │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           ARM Cores (16x A76)                │    │   │
│  │  │                                               │    │   │
│  │  │  - DOCA (OVS, Storage, Security)            │    │   │
│  │  │  - VPP (ARM 端运行)                         │    │   │
│  │  │  - Management                                │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           e-switch / ASAP²                    │    │   │
│  │  │  - 线性转发 (<1μs)                          │    │   │
│  │  │  - 流表卸载                                  │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 VPP on BlueField

```bash
# 在 BlueField ARM 端运行 VPP

# 1. 访问 BlueField ARM
ssh root@192.168.100.1  # BlueField BMC
ssh ubuntu@192.168.100.2  # BlueField ARM

# 2. 安装 VPP on ARM
apt-get install vpp

# 3. 配置 VPP
cat > /etc/vpp/startup.conf << 'EOF'
unix {
  nodaemon
  log /var/log/vpp/vpp.log
  cli-listen /run/vpp/cli.sock
}

cpu {
  main-core 0
  corelist-workers 1-7
}

dpdk {
  socket-mem 4096,4096
  dev 0000:03:00.0
}
EOF

# 4. 启动 VPP
systemctl start vpp

# 5. 配置卸载接口
vpp# show hardware
vpp# set interface state eth0 up
vpp# set interface ip address eth0 10.0.0.1/24
```

### 3.3 OVS 卸载到 BlueField

```bash
# OVS + ASAP² 卸载

# 1. 创建 OVS 桥
ovs-vsctl add-br br0

# 2. 添加 BlueField 端口
ovs-vsctl add-port br0 pf0hpf

# 3. 启用 ASAP² 卸载
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true

# 4. 添加流表
ovs-ofctl add-flow br0 "table=0,ip,nw_dst=10.0.0.0/8,actions=set_field:00:11:22:33:44:55->eth_dst,output:1"

# 5. 查看卸载状态
ovs-dpctl show
ovs-appctl dpctl/dump-flows
```

## 4. Intel IPU

### 4.1 IPU 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Intel IPU (Mount Evans)                   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Host CPU                          │   │
│  │   - 租户工作负载                                    │   │
│  │   - VPP (可选)                                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ PCIe                           │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    IPU Hardware                     │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           100GbE MAC/PHY                      │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           嵌入式多核 (E-core)                 │    │   │
│  │  │                                               │    │   │
│  │  │  - SPDK (存储)                               │    │   │
│  │  │  - OVS (网络)                                 │    │   │
│  │  │  - Security                                  │    │   │
│  │  │  - Host Mgmt                                 │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           DMA 引擎 / CPRCube                  │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 IPU 编程

```bash
# IPU 控制平面

# 1. IPU Firmware 更新
ip-util -f update_firmware ipu_fw.bin

# 2. 配置 IPU 端口
ipu-config set port 0 mode eth
ip u-config set port 0 speed 100G

# 3. 配置流量卸载
ip u-flow create --type=vpp --action=redirect

# 4. 查看 IPU 状态
ip u-show
```

## 5. VPP 卸载路径

### 5.1 卸载架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP + DPU 卸载架构                        │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Host (x86)                        │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │              VPP (完整功能)                    │    │   │
│  │  │                                               │    │   │
│  │  │  - NAT/Firewall                             │    │   │
│  │  │  - 复杂策略                                  │    │   │
│  │  │  - DPI/分析                                  │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                          │                            │   │
│  │                          │ VirtIO/vhost-user          │   │
│  └──────────────────────────┼────────────────────────────┘   │
│                             │                                 │
│                             ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    DPU/IPU                           │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │              ASAP² / OVS HW Offload          │    │   │
│  │  │                                               │    │   │
│  │  │  - 高速 L2 转发                              │    │   │
│  │  │  - SR-IOV 虚拟化                            │    │   │
│  │  │  - 简单流表 (<10 rules)                      │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                          │                            │   │
│  │                          │ DMA                         │   │
│  └──────────────────────────┼────────────────────────────┘   │
│                             │                                 │
│                             ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Physical Network                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 VirtIO 后端卸载

```bash
# VPP 作为 VirtIO 后端 (vhost-user)

# 1. 创建 vhost-user 接口
vpp# create vhost-user socket /run/vpp/vhost-user0.sock server
vpp# set interface state vhost-user0 up

# 2. 配置队列
vpp# set interface virtio queue-size GigEthernet0/0/0 1024

# 3. 启用增强功能
vpp# set interface virtio packed-ring GigEthernet0/0/0 enable

# 4. DPU 端连接
# DPU ARM 运行:
# qemu-system-aarch64 -device virtio-net-pci,mac=...,x-pcie-p扩置-1=on
```

### 5.3 存储卸载

```bash
# VPP + SPDK (DPU 存储卸载)

# 1. 创建 NVMe-oF 目标
spdk/nvmeof/tgt &
spdk/rpc.py bdev_malloc_create --name malloc0 --size 100GB

# 2. 创建 NVMe-oF 命名空间
spdk/rpc.py nvmf_create_subsystem nqn.2016-06.io.spdk:cnode1 -a -s SPDK0001
spdk/rpc.py nvmf_subsystem_add_ns nqn.2016-06.io.spdk:cnode1 malloc0
spdk/rpc.py nvmf_subsystem_add_listener nqn.2016-06.io.spdk:cnode1 -t tcp -a 192.168.1.1 -s 4420

# 3. VPP 通过 DPU 访问
vpp# set interface ip address enp0s1 192.168.1.2/24
vpp# ip route add 192.168.2.0/24 via 192.168.1.1
```

## 6. Broadcom Stingray

### 6.1 Stingray 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Broadcom Stingray DPU                    │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Host CPU                          │   │
│  │   - VPP (VirtIO)                                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Stingray DPU                           │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           2x 100GbE 端口                      │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           ARM Cores (8x A57)                  │    │   │
│  │  │                                               │    │   │
│  │  │  - VPP (ARM 端)                              │    │   │
│  │  │  - OVS                                       │    │   │
│  │  │  - CTF (流表)                                │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  │                                                       │   │
│  │  ┌─────────────────────────────────────────────┐    │   │
│  │  │           RoboSwitch (L2/L3)                 │    │   │
│  │  │  - 硬件转发 (<100ns)                         │    │   │
│  │  │  - ACL                                      │    │   │
│  │  └─────────────────────────────────────────────┘    │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Stingray 配置

```bash
# Stingray DPU 配置

# 1. 访问 ARM 端
ssh ubunt@192.168.100.10  # Stingray ARM

# 2. 安装 VPP
apt-get install vpp

# 3. 配置 VPP
cat > /etc/vpp/startup.conf << 'EOF'
unix {
  nodaemon
  log /var/log/vpp.log
}

cpu {
  main-core 0
  corelist-workers 1-3
}

dpdk {
  socket-mem 1024
  dev 0000:03:00.0
  dev 0000:03:00.1
}
EOF

# 4. 配置网络
vpp# set interface state dpdk0 up
vpp# set interface state dpdk1 up
vpp# set interface ip address dpdk0 10.0.0.1/24

# 5. 配置内部端口
vpp# create vhost-user socket /tmp/vhost0.sock server
vpp# set interface state vhost0 up
```

## 7. 性能对比

### 7.1 卸载收益

|                  | 配置           | CPU 使用 | 延迟    | 吞吐 |
| ---------------- | -------------- | -------- | ------- | ---- |
| **纯软件 VPP**   | 100% (4 cores) | ~15μs    | 10 Gbps |
| **VPP + DPU L2** | 60%            | ~12μs    | 15 Gbps |
| **VPP + DPU L3** | 40%            | ~10μs    | 20 Gbps |
| **DPU 完全卸载** | 10%            | ~5μs     | 50 Gbps |

### 7.2 延迟分解

```
┌─────────────────────────────────────────────────────────────┐
│                    端到端延迟分解                            │
│                                                              │
│  纯软件路径:                                                │
│  NIC DMA ──► Driver ──► VPP ──► App ──► VPP ──► Driver ──► NIC
│  ~5μs        ~2μs    ~10μs   ~5μs   ~5μs    ~2μs      ~5μs
│  Total: ~34μs                                               │
│                                                              │
│  DPU 卸载路径:                                              │
│  NIC DMA ──► DPU ASAP² ──► VirtIO ──► VPP ──► VirtIO ──► DPU ──► NIC
│  ~0.1μs       ~0.1μs     ~0.5μs    ~5μs     ~0.5μs     ~0.1μs   ~0.1μs
│  Total: ~6.4μs (5x 改善)                                    │
└─────────────────────────────────────────────────────────────┘
```

## 8. 总结

```
┌─────────────────────────────────────────────────────────────┐
│                    DPU/IPU + VPP 总结                       │
│                                                              │
│  DPU/IPU 价值:                                              │
│  - 卸载主机网络/存储/安全                                   │
│  - 释放 CPU 资源 (~50%)                                    │
│  - 隔离租户流量                                            │
│  - 硬件级性能                                              │
│                                                              │
│  集成模式:                                                  │
│  1. VPP on DPU ARM                                         │
│  2. VPP + VirtIO 后端                                      │
│  3. OVS/DOCA Flow 卸载                                     │
│  4. 存储卸载 (SPDK)                                        │
│                                                              │
│  主要平台:                                                  │
│  - NVIDIA BlueField (DOCA)                                 │
│  - Intel Mount Evans (IPU)                                 │
│  - Broadcom Stingray                                       │
│                                                              │
│  VPP 角色:                                                  │
│  - 复杂策略处理 (NAT, ACL, DPI)                           │
│  - 主机端 VirtIO 前端                                      │
│  - ARM 端数据平面                                          │
│                                                              │
│  未来趋势:                                                  │
│  - 统一 DPU 编程框架                                       │
│  - VPP 全面支持 DPU                                       │
│  - AI/ML 卸载集成                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## 参考资源

- [NVIDIA DOCA Documentation](https://docs.nvidia.com/doca/)
- [BlueField DPU Documentation](https://docs.nvidia.com/networking/)
- [Intel IPU Documentation](https://www.intel.com/content/www/us/en/products/details/network-io/ipu.html)
- [Broadcom Stingray](https://www.broadcom.com/products/ethernetNICs/stingray)
- [VPP DPU Integration](https://wiki.fd.io/view/VPP/DPU)
