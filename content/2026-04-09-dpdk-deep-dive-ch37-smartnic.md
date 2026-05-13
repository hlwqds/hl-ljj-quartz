---
title: "DPDK 第三十七章：智能网卡 IPU/DPU、Capsule、Barefoot"
date: 2026-04-09 16:20:00
tags: [dpdk, smartnic, ipu, dpu, dpdk, capsule, barefoot, programmable]
description: "深入解析智能网卡架构：IPU/DPU 的演进、Capsule 技术、Barefoot P4 可编程网卡与 DPDK 集成"
---

# DPDK 第三十七章：智能网卡 IPU/DPU、Capsule、Barefoot

> [!abstract] 核心要点
> 智能网卡（SmartNIC）将网络处理卸载到卡上，解放 CPU。本章解析 IPU/DPU 架构、Capsule 技术、Barefoot 可编程网卡，以及它们与 DPDK 的协同。

## 1. 智能网卡概述

### 1.1 为什么需要智能网卡

```
传统架构：
┌──────────┐     ┌──────────┐     ┌──────────┐
│   App    │────▶│   OS     │────▶│   NIC    │────▶ Network
│ (CPU 100%)│     │(Kernel) │     │ (10Gbps) │
└──────────┘     └──────────┘     └──────────┘

智能网卡架构：
┌──────────┐     ┌──────────┐     ┌──────────────────┐
│   App    │────▶│   NIC    │────▶│  Offloaded App   │
│ (CPU 30%) │     │ (Smart)  │     │  (on NIC, 40%)   │
└──────────┘     └──────────┘     └──────────────────┘
```

### 1.2 智能网卡演进

| 时代          | 技术             | 能力                  |
| ------------- | ---------------- | --------------------- |
| **1G/10G**    | 传统 NIC         | 基础收发，无offload   |
| **10G/40G**   | Basic Offload    | checksum、RSS、TSO    |
| **25G/100G**  | Advanced Offload | SR-IOV、flow director |
| **100G+**     | **SmartNIC/IPU** | 可编程、P4、ARM CPU   |
| **200G/400G** | **DPU**          | 完整数据面+控制面     |

### 1.3 术语

| 术语         | 全称                                      | 厂商/来源 |
| ------------ | ----------------------------------------- | --------- |
| **SmartNIC** | Smart Network Interface Card              | 通用术语  |
| **DPU**      | Data Processing Unit                      | NVIDIA    |
| **IPU**      | Infrastructure Processing Unit            | Intel     |
| **DOCA**     | Data Center On A Chip Architecture        | NVIDIA    |
| **IPDK**     | Infrastructure Programmer Development Kit | Intel     |
| **Cape**     | Capsule                                   | Pensando  |
| **Barefoot** | Barefoot Networks (已被 Intel 收购)       | Intel     |

## 2. DPU / IPU 架构

### 2.1 NVIDIA BlueField DPU

```
┌────────────────────────────────────────────────────────────┐
│                      BlueField DPU                         │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              ARM Cores (8x Cortex-A78)             │  │
│  │  - Embedded Linux                                   │  │
│  │  - DOCA runtime                                     │  │
│  │  - vSwitch/Overlay stack                            │  │
│  └──────────────────────┬──────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼──────────────────────────────┐  │
│  │              ConnectX-7 (CX7)                        │  │
│  │  - 400GbE                                          │  │
│  │  - RDMA/RoCE                                       │  │
│  │  - crypto/IPsec                                     │  │
│  │  - DPI engine                                      │  │
│  └──────────────────────┬──────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼──────────────────────────────┐  │
│  │              PCIe Gen 5.0 x16                       │  │
│  └─────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
         │                                    │
         ▼                                    ▼
    ┌─────────┐                         ┌─────────┐
    │ Host CPU│                         │ Network │
    │ (x86)   │                         │ (400G)  │
    └─────────┘                         └─────────┘
```

### 2.2 Intel IPU E810

```
┌────────────────────────────────────────────────────────────┐
│                      Intel IPU E810                        │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              4x Cortex-A72 ARM cores                 │  │
│  │  - SPDK, IPDK runtime                               │  │
│  │  - Open vSwitch                                    │  │
│  └──────────────────────┬──────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼──────────────────────────────┐  │
│  │              Ethernet Controller (icwd)              │  │
│  │  - 200GbE                                          │  │
│  │  - queue management                                 │  │
│  │  - Packet processing                                │  │
│  └──────────────────────┬──────────────────────────────┘  │
│                         │                                   │
│  ┌──────────────────────▼──────────────────────────────┐  │
│  │              FPGA (optional)                        │  │
│  │  - Custom P4 pipelines                             │  │
│  │  - Custom crypto                                    │  │
│  └─────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
```

### 2.3 核心能力对比

| 特性                | BlueField-3 | Intel IPU E810 | Pensando DSC |
| ------------------- | ----------- | -------------- | ------------ |
| **带宽**            | 400GbE      | 200GbE         | 200GbE       |
| **ARM Cores**       | 8x A78      | 4x A72         | 8x A72       |
| **RDMA**            | RoCEv2      | iWARP/RoCE     | RoCEv2       |
| **Crypto**          | IPsec/TLS   | IPsec          | IPsec        |
| **编程方式**        | DOCA/P4     | IPDK/P4        | P4/C         |
| **Storage Offload** | NVMe-oF     | SPDK           | NVMe-oF      |

## 3. Capsule / P4 可编程网卡

### 3.1 Pensando Capsule

Capsule 是 Pensando（现 AMD）的高级可编程网卡架构：

```
┌────────────────────────────────────────────────────────────┐
│                      Capsule Architecture                   │
│                                                            │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              P4 Pipeline (Programmable)              │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
│  │  │ Parser  │─▶│ Match   │─▶│ Action  │─▶│ Deparse │ │
│  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘ │
│  │                                                       │
│  │  State: Counters, Meters, Registers, Liveness       │
│  └─────────────────────────────────────────────────────┘  │
│                          │                                  │
│  ┌───────────────────────▼───────────────────────────────┐ │
│  │              Hardware Arbitrated Bus                   │ │
│  └───────────────────────────────────────────────────────┘ │
│                          │                                  │
│  ┌───────────────────────▼───────────────────────────────┐ │
│  │              Packet DMA Engine                          │ │
│  │  - Host Memory <-> Network                             │ │
│  │  - Zero-copy support                                   │ │
│  └───────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────┘
```

### 3.2 Barefoot Tofino

Intel 收购 Barefoot 后的 Tofino 系列：

| 型号         | 端口      | 可编程管线 | 吞吐量   |
| ------------ | --------- | ---------- | -------- |
| **Tofino**   | 64x 100G  | P4-16      | 6.4Tbps  |
| **Tofino 2** | 128x 100G | P4-16      | 12.8Tbps |
| **Tofino 3** | 256x 100G | P4-16      | 25.6Tbps |

### 3.3 P4 工作流程

```p4
// 在智能网卡上运行的 P4 程序
#include <tofino.p4>

// 定义 header
header ethernet_t { bit<48> dstAddr; bit<48> srcAddr; bit<16> etherType; }
header ipv4_t { ... }

// 定义 actions
action drop() { }
action forward(bit<9> port) {
    standard_metadata.egress_spec = port;
}

// 定义 table
table ipv4_fwd {
    key = { hdr.ipv4.dstAddr: lpm; }
    actions = { forward; drop; }
    size = 32768;
}

// 编译并加载到网卡
# p4c-tofino -p myprogram.p4
# bfshell -c "bf rtadf myprogram.bfconf"
```

## 4. DOCA 架构

### 4.1 DOCA 概述

DOCA 是 NVIDIA BlueField DPU 的 SDK：

```
┌─────────────────────────────────────────────────────────────┐
│                    DOCA SDK                                 │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐   │
│  │   DPDK      │ │   RDMA      │ │   DOCA Flow        │   │
│  │   (ETH)     │ │  (connectX) │ │   (Packet Proc)    │   │
│  └─────────────┘ └─────────────┘ └─────────────────────┘   │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐   │
│  │   Spark   │ │   GPUNetIO  │ │   BlueZip          │   │
│  │  (KV Store)│ │  (GPU)     │ │   (Compression)    │   │
│  └─────────────┘ └─────────────┘ └─────────────────────┘   │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────────────┐   │
│  │   DSA       │ │   RegEx     │ │   DPI              │   │
│  │ (DMA)      │ │  (RegEx)   │ │   (Deep Inspect)   │   │
│  └─────────────┘ └─────────────┘ └─────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 DOCA 与 DPDK

```c
#include <rte_ethdev.h>
#include <doca_ctx.h>
#include <doca_flow.h>

// 在 DPU 上使用 DOCA Flow（类似 rte_flow）
struct doca_flow_port *port;
struct doca_flow_fwd fwd = {
    .type = DOCA_FLOW_FWD_PORT,
    .port_id = 1,
};

struct doca_flow_match match = {
    .out_dst_ip.src_ip = RTE_IPV4(10, 0, 0, 1),
    .out_dst_ip.dst_ip = RTE_IPV4(20, 0, 0, 1),
    .out_l4_type = DOCA_FLOW_L4_TYPE_TCP,
};

struct doca_flow_rule *rule = doca_flow_rule_create(
    pipe, &match, DOCA_FLOW_ATTR_FORWARD, &fwd, 0);
```

## 5. IPDK 架构

### 5.1 IPDK 概述

IPDK (Infrastructure Programmer Development Kit) 是 Intel 的开源框架：

```
┌─────────────────────────────────────────────────────────────┐
│                    IPDK Framework                            │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              GNMI+OpenConfig (Management)             │   │
│  └─────────────────────────┬─────────────────────────────┘   │
│                            │                                  │
│  ┌─────────────────────────▼─────────────────────────────┐   │
│  │                    SDE (Software Data Engine)          │   │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────────────┐    │   │
│  │  │   P4C     │  │  PD CLI   │  │   Pipeline Mgr    │    │   │
│  │  │ Compiler  │  │ (south)  │  │   (JSON config)  │    │   │
│  │  └───────────┘  └───────────┘  └───────────────────┘    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                            │                                  │
│  ┌─────────────────────────▼─────────────────────────────┐   │
│  │                    Target Backend                      │   │
│  │  ┌───────────┐  ┌───────────┐  ┌───────────────────┐    │   │
│  │  │  DPDK     │  │  Kernel   │  │   Tofino/Barefoot │    │   │
│  │  │  (SW)     │  │  (TOFINO) │  │   (HW)           │    │   │
│  │  └───────────┘  └───────────┘  └───────────────────┘    │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 IPDK 与 DPDK 集成

```bash
# 安装 IPDK
git clone https://github.com/ipdk-io/ipdk.git
cd ipdk

# 启动 DPDK target
./install.sh --deps
./install.sh --target dpdk

# 运行 P4 程序
p4c-dpdk -p myprogram.p4 -o myprogram.dpdk.json

# 加载到 DPDK backend
psdb -p myprogram.dpdk.json
```

## 6. DPDK + 智能网卡集成

### 6.1 基础配置

```bash
# 1. 检查网卡型号
lspci -vv | grep -i "network\|ethernet"

# BlueField-3:
# 0000:3d:00.0 Ethernet controller: Mellanox Technologies ...

# 2. 加载驱动
sudo modprobe mlx5_core  # Mellanox
sudo modprobe ice       # Intel E810

# 3. 绑定到 DPDK
sudo dpdk-devbind.py -b mlx5_core 0000:3d:00.0
# 或
sudo dpdk-devbind.py -b vfio-pci 0000:3d:00.0
```

### 6.2 RDMA 卸载

```c
#include <rte_ethdev.h>
#include <rdma/rte_rdma.h>

// 检查 RDMA 能力
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

printf("RDMA supported: %s\n",
       (dev_info.device->driver->drv_flags & RTE_ETH_RDMA) ? "Yes" : "No");

// 使用 RDMA verbs
struct ibv_context *ctx;
struct ibv_pd *pd;
struct ibv_cq *cq;
struct ibv_qp *qp;

// 与 DPDK mbuf 集成
// 使用 RDMA send/recv 替代 socket
```

### 6.3 Crypto 卸载

```c
#include <rte_cryptodev.h>

// 使用网卡上的 crypto engine
struct rte_cryptodev_info dev_info;
uint8_t cryptodev_id = 0;

rte_cryptodev_info_get(cryptodev_id, &dev_info);
printf("Crypto driver: %s\n", dev_info.driver_name);

// 配置 crypto session
struct rte_crypto_sym_session *session;
session = rte_cryptodev_sym_session_create(cryptodev_id,
    &cipher_xform, &auth_xform);

// 处理加密流量
```

## 7. 典型应用场景

### 7.1 vSwitch 卸载

```bash
# 将 OVS 卸载到 DPU
# BlueField 上的 OVS 分支
ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl add-br br0 -- set Bridge br0 datapath_type=netdev

# 连接 VF 到 OVS
ovs-vsctl add-port br0 dpdk0
ovs-vsctl add-port br0 vf0

# 验证卸载
ovs-ofctl show br0
# 应该显示硬件卸载端口
```

### 7.2 storage NVMe-oF 卸载

```c
// 使用 DOCA Storage
#include <doca_storage.h>

struct doca_storage_export *exp;
struct doca_storage *storage;

// 导出 NVMe 命名空间
doca_storage_export_create(nvme_ns, &exp);
doca_storage_export_set_remote(exp, "192.168.1.100");
doca_storage_export_start(exp);

// DPU 透明处理 NVMe-oF RDMA
```

### 7.3 网络功能链式卸载

```
┌─────────────────────────────────────────────────────────────┐
│  Chain: Firewall → Load Balancer → DPI → IPSec            │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              P4 Pipeline (Programmable NIC)         │    │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────┐ │    │
│  │  │ Firewall │→│   LB     │→│   DPI    │→│IPSec  │ │    │
│  │  │ (match)  │ │ (ECMP)   │ │ (regex)  │ │(crypto)│ │    │
│  │  └──────────┘ └──────────┘ └──────────┘ └───────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

## 8. 总结

智能网卡是 DPDK 高性能网络的关键：

1. **DPU/IPU**：将基础设施功能从 CPU 卸载
2. **P4 可编程**：灵活定义数据面处理流水线
3. **DOCA/IPDK**：统一的 SDK 抽象
4. **RDMA/Crypto**：硬件加速数据传输和加密
5. **NVMe-oF**：存储卸载减少 CPU 参与

---

## 参考资源

- [NVIDIA DOCA 文档](https://docs.nvidia.com/doca/)
- [Intel IPU 文档](https://www.intel.com/content/www/us/en/products/details/io/infrastructure-processing-units.html)
- [IPDK GitHub](https://github.com/ipdk-io/ipdk)
- [P4.org](https://p4.org/)
