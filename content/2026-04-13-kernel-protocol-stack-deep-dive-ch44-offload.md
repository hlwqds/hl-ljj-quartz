---
title: "Kernel Protocol Stack 深度探索 (四十四)：硬件 offload"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    hardware-offload,
    smartnic,
    flow-director,
    rdma,
    switchdev,
    dpdk,
  ]
description: "深入解析网卡硬件 offload——Flow Director、Switchdev、RDMA、TOE、 checksum offload、以及智能网卡架构，帮助理解何时使用硬件 offload 与其性能边界"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 43. [[2026-04-13-kernel-protocol-stack-deep-dive-ch43-bpf-hook|第四十三章：Linux BPF 网络钩子]] 44. **第四十四章：硬件 offload** 45. [[2026-04-13-kernel-protocol-stack-deep-dive-ch45-tuning|第四十五章：网络性能调优]]

---

## 1. 硬件 offload 概述

Linux 网络协议栈的处理可以卸载到网卡硬件，常见 offload 类型：

| Offload 类型         | 协议       | 方向  | 功能               |
| -------------------- | ---------- | ----- | ------------------ |
| **Checksum offload** | TCP/UDP/IP | TX/RX | 校验和计算         |
| **TSO/UFO**          | TCP/UDP    | TX    | 分段/分片          |
| **GRO/LRO**          | TCP        | RX    | 合并分段           |
| **RSS**              | 通用       | RX    | 多队列分发         |
| **Flow Director**    | IP/TCP     | RX    | 精确流分类         |
| **Switchdev**        | L2         | RX    | 交换芯片转发       |
| **RDMA**             | 传输层     | RX    | 零拷贝远程内存访问 |
| **TOE**              | TCP        | TX    | TCP offload engine |

---

## 2. Flow Director

### 2.1 Flow Director 原理

**Flow Director** 是 Intel 网卡（如 82599, X710, XL710 系列）的精确流匹配技术。它使用网卡上的 **EM（Exact Match）表**将特定 flow 直接送到指定 RX 队列：

```
传统 RSS:
  flow_hash(5-tuple) % num_queues → 队列（概率均匀，可能打散同一 flow）

Flow Director:
  管理员配置: {src_ip=X, dst_ip=Y, src_port=A, dst_port=B} → RX Q2
  命中则: 直接送到 RX Q2（100% 保序 + 极低延迟）
```

### 2.2 Flow Director 与 RSS 的区别

| 特性         | RSS                        | Flow Director           |
| ------------ | -------------------------- | ----------------------- |
| **匹配方式** | 哈希（概率均匀）           | 精确匹配（exact match） |
| **灵活性**   | 自动                       | 需手动配置              |
| **流保序**   | 可能打散（不同 hash 碰撞） | 100% 保序               |
| **CPU 效率** | 好                         | 极好（送到专用 cache）  |
| **表大小**   | 256 entry indirection      | 64K EM 表               |

### 2.3 配置 Flow Director

```bash
# 查看 Flow Director 状态
ethtool -k eth0 | grep -i fdir

# 输出：
# flow-director-atr: on      # ATR = Auto RSS, 自动学习 flow
# flow-director-l4: on        # L4 精确匹配
# flow-director-tos: off

# 查看 Flow Director 统计
ethtool -S eth0 | grep -i fdir

# 添加 Flow Director 规则（ethtool 工具）
# 将目标端口 80 的 TCP 流送到 RX 队列 2
ethtool -U eth0 flow-type tcp4 dst-port 80 action 2

# 添加精确 5-tuple 规则
ethtool -U eth0 \
    flow-type tcp4 src-ip 192.168.1.10 dst-ip 192.168.1.20 \
    src-port 12345 dst-port 80 action 3

# 清除所有规则
ethtool -U eth0 delete 0
```

### 2.4 Flow Director 的应用场景

```
NFV / vRouter:
  控制平面: flow-director 将管理流量送到特定队列（CPU 处理）
  数据平面: RSS 正常分发

DPDK + Flow Director:
  将特定 flow 绑定到特定 DPDK lcore，实现：
  - 每个 flow 在同一 CPU 处理（cache 友好）
  - 不同 flow 并行处理（负载均衡）
```

---

## 3. Switchdev 模式

### 3.1 Switchdev 概述

**Switchdev** 是在 Linux 内核中实现**硬件交换机**（Switch ASIC）的框架。它将交换芯片暴露为标准的 Linux netdevice，允许内核的 bridge、bond、vlan 等 L2 机制直接 offload 到硬件：

```
传统软件桥接:
  eth0 ──► [bridge] ──► eth1
             ▲
             └── CPU 处理（学习、转发、FDB）
             瓶颈: CPU 无法线速处理 100G+ 交换

Switchdev 硬件桥接:
  eth0 ──► [Switch ASIC] ──► eth1
             ▲
             └── 硬件自主转发（线速）
             CPU: 仅处理控制平面（Snooping、STP）
```

### 3.2 Switchdev 架构

```bash
# switchdev 设备通常是一个虚拟 switch（Representor）
# 每个物理 port 都是一个 representor netdevice

# 查看 switchdev 设备
ls /sys/class/net/

# sw0p0, sw0p1, sw0p2 ... 是 port representors
# sw0 是 switch device
```

Switchdev 驱动的核心结构：

```c
// include/linux/net_device.h
struct net_device {
    // ...
    const struct switchdev_ops *switchdev_ops;  // 交换芯片操作
    // ...
};

struct switchdev_ops {
    int (*switchdev_port_attr_get)(struct net_device *dev,
                                    struct switchdev_attr *attr);
    int (*switchdev_port_attr_set)(struct net_device *dev,
                                    struct switchdev_attr *attr,
                                    struct netlink_ext_ack *extack);
    int (*switchdev_port_obj_add)(struct net_device *dev,
                                   struct switchdev_obj *obj,
                                   struct netlink_ext_ack *extack);
    // ...
};
```

### 3.3 Bridge offload 到 switchdev

```bash
# 创建 bridge
ip link add br0 type bridge

# 添加 ports（会自动 offload 到 switchdev）
ip link set eth0 master br0
ip link set eth1 master br0

# 查看 offload 状态
bridge link

# 输出：
# 2: eth0 master br0 state forwarding             # offloaded=yes
# 3: eth1 master br0 state forwarding
# 如果 switchdev 支持，应该显示 offload: on
```

### 3.4 tc flower offload 到 switchdev

```bash
# tc flower 规则可以被 switchdev 卸载到硬件
tc qdisc add dev eth0 ingress

# 添加 flower 规则
tc filter add dev eth0 ingress \
    protocol ip \
    flower \
    dst_ip 10.0.0.1 \
    action drop

# 查看规则是否 offload
tc filter show dev eth0 ingress

# 关键：hw_stats = 硬件计数
tc filter add dev eth0 ingress \
    protocol ip \
    flower \
    hw_stats both \
    action drop
```

---

## 4. RDMA

### 4.1 RDMA 概述

**RDMA（Remote Direct Memory Access）** 是一种直接内存访问技术，允许服务器之间**绕过 CPU 和操作系统内核**直接读写对方内存：

```
传统 TCP:
  App A → 内核协议栈 → 网卡 → 线缆
  App B ← 内核协议栈 ← 网卡 ← 线缆
  瓶颈: CPU 处理（copy、checksum、协议）

RDMA:
  App A → RDMA 网卡 → 直接到 App B 的内存
  瓶颈: 极低（网卡 DMA 直接内存）
```

### 4.2 RDMA 关键概念

| 概念                             | 说明                                    |
| -------------------------------- | --------------------------------------- |
| **QP (Queue Pair)**              | RDMA 的通信端点，包含 SendQ/RecvQ/RQ/SQ |
| **PD (Protection Domain)**       | 安全隔离域                              |
| **MR (Memory Region)**           | 已注册的内存区域（可用于 DMA）          |
| **WQE (Work Queue Element)**     | RDMA 操作请求                           |
| **CQE (Completion Queue Entry)** | 操作完成通知                            |
| **verbs**                        | RDMA API（libibverbs）                  |

### 4.3 Linux RDMA 栈

```
用户空间:
  libibverbs (OFED) → 包装 RDMA verbs
        │
        ▼
  rdma-core (userspace RDMA 管理)
        │
        ▼
内核驱动:
  rdma_cm (连接管理) + irdma/mlx5/RoCE drivers
        │
        ▼
硬件:
  InfiniBand / RoCE / iWARP 网卡
```

Linux 内核的 RDMA 子系统：

```c
// drivers/infiniband/core/
// - rdma_cm.c: 连接管理（CM）
// - ucma.c: 用户空间 CM API
// -uverbs: 用户空间 verbs 接口
```

### 4.4 RDMA vs TOE

```
RDMA:  绕过内核，用户直接访问远端内存（零拷贝）
TOE:   保留内核，但 TCP checksum/segmentation 卸载到网卡
       仍需要内核处理，仍然有 context switch 开销

实际: RDMA 比 TOE 更快，但需要特殊硬件（IB/RoCE）和应用程序改造
```

---

## 5. TOE：TCP Offload Engine

### 5.1 TOE 原理

**TOE（TCP Offload Engine）** 将整个 TCP 协议栈（包括连接状态、重传、拥塞控制）卸载到网卡：

```
完整 TOE:
  网卡处理: 连接状态机、重传、拥塞控制、滑动窗口
  CPU: 只处理应用层数据（send/recv buffer 交互）

部分 TOE（更常见）:
  网卡处理: checksum、segmentation、header construction
  CPU: 协议栈逻辑（状态机、重传、拥塞控制）
  例: TOE 就是 TSO + checksum offload 的组合
```

### 5.2 Linux 对 TOE 的支持

Linux 的 TOE 支持**非常有限**：

- 内核有 `NETIF_F_FCOE_MTU` 等特性，但没有完整的 TCP offload engine
- 大部分 TOE 功能通过 **TSO/GSO/Checksum offload** 的组合实现
- 原因：TCP 连接状态复杂，网卡无法高效处理

```bash
# 查看网卡支持的 offload
ethtool -k eth0

# 典型的 offload 组合：
# tcp-segmentation-offload: on    # TOE 的核心
# generic-segmentation-offload: on
# generic-receive-offload: on
# tx-checksum-ip-generic: on
# tx-checksum-ipv4: on
# tx-checksum-ipv6: on
```

---

## 6. 智能网卡（SmartNIC）

### 6.1 SmartNIC 架构

现代 SmartNIC（如 Nvidia BlueField, Intel IPU, Xilinx Alveo）内部有一个**嵌入式的 ARM/微控制器**，可以运行完整的协议栈或用户自定义程序：

```
传统网卡:
  仅有 DMA 引擎 + PHY
  所有协议栈在 CPU 运行

SmartNIC:
  ┌─────────────────────────────────┐
  │  Embedded ARM cores (通常 8-16 核) │
  │  - 运行完整 Linux                 │
  │  - 运行用户空间 DPDK/VPP           │
  │  - 或者运行固件协议栈               │
  ├─────────────────────────────────┤
  │  FPGA / NPU                      │
  │  - 可编程数据包处理               │
  │  - 硬件 offload                  │
  ├─────────────────────────────────┤
  │  DMA + PHY                       │
  │  - 高速收发                       │
  └─────────────────────────────────┘

  宿主机 CPU ←→ PCIe ←→ SmartNIC ARM/FPGA ←→ 光纤
```

### 6.2 SmartNIC 的使用模式

**模式 1：Offload OVS/Vswitch 到 SmartNIC**

```bash
# BlueField 的典型架构
# OVS data plane 在 ARM 核心上运行
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true

# 所有 packet 处理在 SmartNIC 内完成
# 宿主机 CPU 零介入
```

**模式 2：用户空间 DPDK on SmartNIC**

```bash
# 在 SmartNIC 的 ARM 核心上运行 DPDK 应用
# 通过 PCIe 被宿主机使用
dpdk-testpmd -l 0-7 -n 4 -- -i
```

### 6.3 OVS Hardware Offload (OvS-DPDK)

```bash
# 启用 OvS-DPDK 硬件 offload
ovs-vsctl set Open_vSwitch . other_config:hw-offload=true

# 配置 datapath 类型
ovs-vsctl set datapath_type=netdev

# 创建 offload 规则
ovs-ofctl add-flow br0 "actions=set_field:00:11:22:33:44:55->dst_mac,output:1"
```

---

## 7. 何时使用硬件 offload

### 7.1 选择决策树

```
需要 10Gbps 以下吞吐?
  → 内核网络栈 + RSS + TSO 足够

需要 10-40Gbps?
  → 启用 TSO/GRO + RSS + CPU 绑定
  → 考虑 XDP 处理特殊流量

需要 40-100Gbps?
  → DPDK/VPP 用户态方案
  → 或者 SmartNIC offload

需要极低延迟 (< 10us)?
  → RDMA / RoCE
  → 或者专用低延迟网卡 (Solarflare, Exablaze)

需要灵活策略 (DPI, Firewall)?
  → XDP + BPF + 智能网卡
  → 或 DPDK + 用户态协议栈
```

### 7.2 offload 兼容性矩阵

| 功能           | 传统网卡 | 高级网卡 (X710) | SmartNIC (BlueField) |
| -------------- | -------- | --------------- | -------------------- |
| TSO/GRO        | ✅       | ✅              | ✅                   |
| RSS (16+ 队列) | ✅       | ✅              | ✅                   |
| Flow Director  | ❌       | ✅              | ✅                   |
| Switchdev      | ❌       | ❌ (部分)       | ✅                   |
| RDMA           | ❌       | ❌              | ✅ (可选)            |
| XDP            | ❌       | ✅ (驱动支持)   | ✅                   |
| 可编程流水线   | ❌       | ❌              | ✅ (FPGA)            |

---

## 8. 总结

硬件 offload 的核心思想是**将确定性的数据包处理从 CPU 移到网卡**，让 CPU 专注于应用逻辑：

- **基础 offload**（TSO/GRO/RSS/Checksum）：几乎所有现代网卡都支持，是 Linux 网络高性能的基础
- **Flow Director**：适合 NFV、负载均衡场景，需要精确流控制
- **Switchdev**：适合多租户交换，OVS 硬件 offload
- **RDMA**：适合 HPC、AI 训练、存储，需要极低延迟和极高高吞吐
- **SmartNIC**：将整个数据平面移到网卡，适合超大规模云计算

选择 offload 策略时，关键是理解数据路径的瓶颈在哪里，以及应用程序是否能够充分利用 offload 能力。
