---
title: "DPDK 深度探索 ch35：SR-IOV 与 VF 管理机制"
date: 2026-04-09 16:00:00
tags:
  [
    dpdk,
    sr-iov,
    vf,
    pf,
    pci-sig,
    vfio,
    switchdev,
    representor,
    vf-token,
    vf-migration,
    mlx5,
    i40e,
    ice,
  ]
description: "深入解析 SR-IOV 的 PCIe 规范层机制：ARI / PF/VF BAR / MSI-X / embedded switch / queue scheduler / VF token / live migration 协议，并对比 i40e / ice / mlx5 三大主流驱动的实现差异"
---

# DPDK 深度探索 ch35：SR-IOV 与 VF 管理机制

> [!info] 关联章节
>
> - [[ch32-sriov-vf|第三十五章补充 ch35a：SR-IOV 实战]]（创建、VFIO 绑定、trust / spoof / VLAN / rate limit）
> - [[ch2-uio-vfio-iommu|第二章：UIO/VFIO/IOMMU]]（VF 怎么被 DPDK 拿到）
> - [[ch16-vhost-user|第十六章：vhost-user 与 virtio 加速]]（SR-IOV 与 vhost-user 的取舍）
> - [[ch19-vdpa|第十九章：VDPA]]（vDPA + SR-IOV 的硬件卸载路径）
> - [[ch19b-dpu-smartnic|第十九章补充：DPU/SmartNIC]]
> - [[ch34-live-migration|第三十四章：热迁移]]（VF live migration）

> [!abstract] 核心要点
> SR-IOV 不是“把网卡直通给 VM 那么简单”——它是 PCI-SIG 定义的一套**完整的硬件+固件+驱动协同规范**：
>
> 1. **PCIe 扩展能力**：在 PCI config space 里新增 capability 结构，让单个物理 function 报出多个独立 function
> 2. **VF 资源切片**：把 BAR、MSI-X、队列、FIFO 切给每个 VF；切多切少由 PF 驱动和 NIC firmware 决定
> 3. **嵌入式交换机**：NIC 内部有个 L2 switch，把 VF / PF / uplink 三个口串起来
> 4. **控制平面**：所有 VF 配置（MAC / VLAN / rate / trust / spoofchk）走 PF 驱动下发到固件
> 5. **热迁移友好性**：mlx5 ConnectX-5/6/7 支持 VF 状态透明同步，i40e/ice 不支持
>
> 本章专门讲**机制层**——PCIe 协议、固件交互、不同 NIC 厂商实现差异。**实战创建、VFIO 绑定、安全配置**在 ch35a。

---

## 1. SR-IOV 的本质：PCIe capability + 资源切分

### 1.1 传统 PCIe 设备的 config space

```text
┌─────────────────────────────────────┐
│ Standard PCI Header (64 bytes)     │
├─────────────────────────────────────┤
│ Capability List (可变长)             │
│  ├─ Power Management (cap 0x01)    │
│  ├─ MSI / MSI-X (cap 0x05/0x11)    │
│  ├─ PCIe (cap 0x10)                │
│  └─ ...                             │
└─────────────────────────────────────┘
```

一个 PCIe 设备上报一次 config space，由 kernel 的 `pci_bus_type` 匹配驱动。

### 1.2 SR-IOV 扩展：多 function 上报

```text
┌────────────────────────────────────────────────┐
│ PF Config Space                                 │
│  ├─ Standard PCI Header                         │
│  ├─ SR-IOV Capability (cap 0x10)               │
│  │    ├─ SR-IOV Control Register               │
│  │    ├─ SR-IOV Status Register                │
│  │    ├─ InitialVFs / TotalVFs / NumVFs        │
│  │    ├─ First VF Offset (VF0 BDF)             │
│  │    ├─ VF Stride                             │
│  │    └─ VF Device ID                          │
│  ├─ ARI (Alternative Routing ID Interpretation)│
│  │    └─ 让 function 号支持 8 bits (0-255)    │
│  │       解决 function 0-7 不够用              │
│  └─ 其他 capability                              │
└────────────────────────────────────────────────┘

SR-IOV Cap 结构 = 0x10（PCI-SIG 分配）
ARI Cap 结构    = 0x12
```

**关键点**：VF **不是**"软件模拟的 PCIe function"，它是 NIC 固件在 PCIe fabric 上**真实**呈现的 function。`lspci` 能看到，跟普通 PCI 设备一样枚举。

### 1.3 实际看到的 BDF

```text
PF:  0000:3d:00.0   ← 主设备
VF0: 0000:3d:02.0   ← 由 First VF Offset + 0 * Stride 算出
VF1: 0000:3d:02.1
VF2: 0000:3d:02.2
...
VF7: 0000:3d:02.7
```

`lspci -k -s 0000:3d:00.0`：

```text
00:02.0 Ethernet controller: Intel Corporation XL710 VF
        Subsystem: Intel Corporation XL710 VF
        Kernel driver in use: vfio-pci
```

`lspci -k` 看到的 kernel driver 是 **VF 的**（vfio-pci / i40evf / mlx5_core）。**PF 自己的 driver 跟 VF 是不同的代码**（i40e vs i40evf、ice 既是 PF 也是 VF、mlx5_core 共享）。

### 1.4 ARI 的作用

```text
传统 PCIe 8 bits function (0-7)
  → 一台设备最多 8 function
  → 8 个 VF 起步就满了，256 VF 不可能

ARI (Alternative Routing ID Interpretation)
  → function 号 8 bits → 0-255
  → 配合 SR-IOV 才能支持 256 VF (E810)
```

> [!note] 现代 NIC 普遍依赖 ARI
> 启用 SR-IOV 前先确认 BIOS 打开 ARI + ACS：
>
> ```
> SR-IOV: Enabled
> ARI:    Enabled
> ACS:    Enabled    (Access Control Services, 防止 P2P 攻击)
> ```

---

## 2. VF 资源切分：硬件到底把什么给了 VF

### 2.1 资源清单

```text
每个 VF 独立拥有：
  ① 自己的 PCI config space (4 KB)
  ② 自己的 BAR（一般 1 个，多为 MMIO 寄存器窗口）
  ③ 自己的 MSI-X 中断向量
  ④ 自己的 DMA 引擎
  ⑤ 自己的 queue pair（RX + TX）
  ⑥ 自己的 L2 filter（MAC / VLAN）
  ⑦ 自己独立的统计计数器
  ⑧ 自己的 TC / QoS 配额

每个 VF 共享：
  · NIC 物理端口（uplink）
  · 总 RX/TX 带宽（按 NIC 调度算法）
  · 共享 L2 forwarding table
  · firmware 控制寄存器
```

### 2.2 queue 分配怎么算

```text
NIC 物理资源：
  总 RX queue 数 = N
  总 TX queue 数 = N
  每个 PF 拿 1-2 个 + N-2 平均分给 VF
  或者：每个 VF 拿固定 K 个
```

不同 NIC 实现：

| NIC                     | VF queue 分配                          |
| ----------------------- | -------------------------------------- |
| Intel i40e (X710/XL710) | PF 16，VF 最多 16。**总和 = 总队列数** |
| Intel ice (E810)        | PF 16-256，VF 最多 16                  |
| Mellanox ConnectX-5/6   | PF 多个，VF 共享总队列（弹性）         |
| Broadcom NetXtreme      | 静态分配                               |

**配置命令**：

```bash
# 启动 EAL 时给 VF 分 4 队列
dpdk-app -l 0-7 -n 4 \
  -- \
  -a 0000:3d:02.0,queue-rx=4,queue-tx=4
```

> [!tip] queue 分配 vs 实际 lcore 数
> 队列数 < lcore 数 → 有 lcore 闲置
> 队列数 > lcore 数 → 1 个 lcore 处理多队列（轮询），影响性能
> **最佳 = 队列数 = RSS 数 ≤ lcore 数**

---

## 3. NIC 嵌入式交换机（Embedded Switch）

### 3.1 为什么是“交换机”

VF 拿到的是 NIC 内部的**虚拟端口**，不是物理端口。NIC 固件内嵌一个 L2 交换机把：

```text
┌───────────────────────────────────────────────┐
│                NIC 内部 Embedded Switch        │
│                                                │
│   PF (representor) ─┐                         │
│   VF0 (representor)─┤                         │
│   VF1 (representor)─┼─→ Embedded Switch ─→    │
│   VF2 (representor)─┤        │                │
│   ...               ┘        │                │
│                              ↓                │
│                      Physical Uplink (PHY)    │
└───────────────────────────────────────────────┘
```

**关键概念**：每个内部端口都有个 **representor**（在 switchdev 模式下），Host 通过 representor 观察 VF 的包。

### 3.2 两种工作模式

| 模式               | 出现时间    | Host 视角                          | DPDK 视角                            |
| ------------------ | ----------- | ---------------------------------- | ------------------------------------ |
| **Legacy mode**    | 早期        | VF 是独立 PCI 设备，不可见转发行为 | DPDK 拿 VF 直接收发                  |
| **switchdev mode** | kernel 4.8+ | 看到 representor 接口，可编程转发  | 仍按 VF 收发，但转发由 firmware 决策 |

**启用 switchdev**（mlx5）：

```bash
# 进入 switchdev
devlink dev eswitch set pci/0000:03:00.0 mode switchdev

# 看 representor 接口
ip link show
# ens3f0v0: <BROADCAST,MULTICAST>  ← representor for VF0
# ens3f0v1: <BROADCAST,MULTICAST>  ← representor for VF1

# 用 tc 抓包（在 representor 上）
tc qdisc add dev ens3f0v0 ingress
```

> [!warning] 模式切换是破坏性操作
> `devlink eswitch set mode switchdev` 之后该 PF 上的所有 VF 都会受影响，
> 已激活的 VM 会**断网**。生产只能在新装机/维护窗口做。

### 3.3 VF ↔ VF 通信

```text
默认配置：VF 之间不互通（forward=0）
打开方式（mlx5）：

devlink dev eswitch set pci/0000:03:00.0 mode switchdev
# 默认：VF 间隔离，所有 VF 只能到 uplink
# 改：allow VF↔VF 通信
```

**安全意义**：在 NFV 多租户场景下，VF 间默认隔离是基础安全要求——一个租户的 VM 不能直接访问另一个租户的 VM。

---

## 4. PF 驱动的“控制平面”

PF 驱动是 VF 配置的**唯一入口**。所有 VF 的状态变更都要走 PF：

```text
ip link set eth0 vf 0 mac aa:bb:cc:dd:ee:ff
        ↓
PF 驱动 (i40e / ice / mlx5_core)
        ↓
ioctl 到 PF 的 MMIO
        ↓
NIC firmware 写 VF config 寄存器
        ↓
VF 重新 reset + 应用新配置
```

### 4.1 三大厂商 PF 驱动对比

| 特性                  | i40e (X710/XL710)                       | ice (E810) | mlx5_core (ConnectX)                    |
| --------------------- | --------------------------------------- | ---------- | --------------------------------------- |
| **最大 VF**           | 64                                      | 256        | 128                                     |
| **trust 模式**        | 通过 `ip link set <pf> vf <n> trust on` | 同         | 通过 `ip link set <pf> vf <n> trust on` |
| **rate limit**        | `min_tx_rate` / `max_tx_rate` (Mbps)    | 同         | 同 + 高级 scheduling                    |
| **spoof check**       | 编译时常开，运行时关不掉                | 可配       | 可配                                    |
| **VLAN filter**       | per-VF tag + qos                        | 同         | 同 + trunk mode                         |
| **switchdev**         | ❌                                      | ❌         | ✅（最佳）                              |
| **VF live migration** | ❌                                      | ❌         | ✅（ConnectX-5/6/7）                    |
| **vDPA**              | 部分                                    | 部分       | ✅（最成熟）                            |
| **代表 OS 兼容**      | 全主流                                  | 全主流     | 全主流 + RDMA 栈                        |

### 4.2 DPDK 视角的驱动文件命名

```text
drivers/net/i40e/         ← PF
drivers/net/i40evf/        ← VF (运行在 VM 内)
drivers/net/ice/           ← PF + VF 共享
drivers/net/mlx5/          ← 共享
drivers/net/mlx5_vdpa/     ← vDPA backend
drivers/raw/ifpga/         ← raw IFPGA
```

DPDK 拿到 VF 后的 device name：

```text
i40evf_pmd  (VF inside VM using i40e PF)
ice_vf      (VF inside VM using ice PF)
mlx5_core   (VF in same driver family)
```

### 4.3 PF 驱动的“控制平面”能力清单

```text
ip link show dev <pf>  → 列所有 VF 的状态
ip link set <pf> vf <N> mac <mac>          ← 改 MAC
ip link set <pf> vf <N> vlan <id>         ← 设 VLAN
ip link set <pf> vf <N> qos <0-7>         ← 802.1p priority
ip link set <pf> vf <N> rate <Mbps>       ← 简单 rate limit (i40e 不支持 min)
ip link set <pf> vf <N> max_tx_rate <Mbps>
ip link set <pf> vf <N> min_tx_rate <Mbps>
ip link set <pf> vf <N> spoofchk on/off
ip link set <pf> vf <N> trust on/off
ip link set <pf> vf <N> state enable/disable
ip link set <pf> vf <N> link-state auto/enable/disable

# devlink 是新的低层接口（iproute2 4.7+）
devlink dev show
devlink port show
devlink resource show
devlink health show
devlink trap show
```

> [!warning] 改 VF MAC/VLAN 会**重置 VF**
> 内部流程是：停 VF → 改寄存器 → 重启 VF。在 VM 看来会有 1-3 秒的网络中断。
> 生产要在维护窗口改。

---

## 5. VF Token：防止同型号网卡多主机部署时 VF MAC / PCI 地址冲突

### 5.1 问题

```text
Host A                            Host B
  ├─ eth0 (PF, 同型号 NIC)         ├─ eth0 (PF, 同型号 NIC)
  │  ├─ VF0 (00:11:22:33:44:55)    │  ├─ VF0 (00:11:22:33:44:55)  ← MAC 撞了
  │  └─ VF1 (00:11:22:33:44:56)    │  └─ VF1 (00:11:22:33:44:56)  ← MAC 撞了

两台 host 各自拥有独立网卡，但同型号 NIC 使用相同 OUI 前缀生成 VF MAC，
导致同一广播域内出现重复 MAC 地址。
```

### 5.2 VF Token 机制

```text
VF Token = 16 bytes 字符串
  - 每个 host 配不同的 token
  - 创建 VF 时 kernel 把 token 写进 VF 的 PCI config space
  - QEMU / dpdk / 容器 启动时必须传匹配的 token
  - 否则拒绝绑定

目的：
  1. 防止 PCI 地址撞车时把别 host 的 VF 当自己的
  2. 防止 libvirt / K8s 调度器误绑
```

### 5.3 配置方式

```bash
# Host 端：设置 token
echo "myhost-A-token-123" > /sys/bus/pci/devices/0000:3d:00.0/sriov_vf_token

# QEMU 端：匹配 token
qemu ... -device vfio-pci,host=0000:3d:02.0,vf-token=myhost-A-token-123

# Kubernetes + SR-IOV CNI
apiVersion: v1
kind: Pod
metadata:
  annotations:
    k8s.v1.cni.cncf.io/networks: sriov-net
spec:
  containers:
  - name: app
    resources:
      requests:
        intel.com/sriov_vf_token: "myhost-A-token-123"  # 配合 device plugin
```

> [!note] 现代 NIC 默认 token
> 大多数新 NIC（i40e / ice / mlx5）firmware 自动生成 token，不需要手配。
> 老 NIC 或 VM migration 场景里要手设。

---

## 6. VF Live Migration（mlx5 独有）

### 6.1 为什么 i40e/ice 不支持

```text
i40e / ice: VF 状态（队列指针、FIFO 深度、内部定时器）**没有暴露给软件**
  → 透明迁移：要在 firmware 侧同步状态，Intel 没做

mlx5 ConnectX-5/6/7:
  - firmware 暴露了 VF 状态寄存器
  - kernel 通过 VFIO migration API 访问
  - 透明迁移：状态随 VF 一起 DMA 到目的端
```

### 6.2 mlx5 透明迁移协议

```text
源端 Host                            目的端 Host
  │                                      │
  ├─ VF 0 正在 VM 中运行                  │
  │                                      ├─ 预分配 VF 0 (同样 BDF)
  │                                      ├─ 绑到 vfio-pci
  │                                      ├─ VF 状态 = paused
  │                                      │
  │   QEMU migrate                        │
  │                                      │
  │                                      ├─ VF 状态 → save
  │                                      ├─ 内部 DMA：把 firmware 状态搬过去
  │                                      ├─ VF 状态 → resume
  │                                      │
  │  内存 + CPU 继续搬（QEMU）            │
  │                                      │
  │  目标 QEMU 启动，VF 状态由 firmware 接管 │
```

### 6.3 VFIO migration device 操作

```bash
# 看 VF 是否支持 migration
$ lspci -vvv -s 0000:03:00.4 | grep -i migrat
   Supports Migration: Yes

# QEMU 启动
qemu ... -device vfio-pci,host=0000:03:00.4,...
# vfio-pci 自动检测 migration 能力

# 配合 QEMU migrate 命令（详见 ch34）
(qemu) migrate tcp:dst:4444
```

### 6.4 性能数据（mlx5 ConnectX-6 100G NIC）

| VM 内存 | 预拷贝 | 停机      | 备注        |
| ------- | ------ | --------- | ----------- |
| 4 GB    | 5-10s  | 200-400ms | 业务 1 Gbps |
| 8 GB    | 10-25s | 200-500ms | 业务 1 Gbps |
| 32 GB   | 30-90s | 300-600ms | 业务 1 Gbps |

> [!danger] i40e/ice 上 VM 不能 live migration
> 用 i40e/ice 的 VM 想迁移必须**先卸载 VF 驱动、改成 vhost-user**——停机分钟级。
> 这是 5G UPF 等场景用 mlx5 的核心原因。

---

## 7. VF 与 IOMMU 隔离

### 7.1 三层防护

```text
① 物理隔离：
   - VF 只能 DMA 自己申请过的内存页
   - 由 IOMMU（VT-d / AMD-Vi）强制

② firmware 隔离：
   - VF 不能读其他 VF 的内部寄存器
   - 每个 VF 的 BAR 范围独立

③ host driver 隔离：
   - PF 驱动可以拒绝未授权的 MAC spoof
   - spoof check / trust / VLAN 过滤
```

### 7.2 IOMMU 启用

```bash
# 内核参数
intel_iommu=on iommu=pt
#  intel_iommu=on: 启用 VT-d
#  iommu=pt: passthrough 模式，更高性能

# 验证
dmesg | grep -i dmar
# DMAR: IOMMU enabled

# 确认 VF 在 IOMMU group
ls /sys/kernel/iommu_groups/ | head
# 找对应 group
ls /sys/kernel/iommu_groups/12/devices/
```

> [!warning] 跨 NUMA / 跨 IOMMU group 性能差
> 同一张 NIC 的多个 VF 默认在**不同 IOMMU group**（ACS 启用情况下），
> 跨 group 的 DMA 会受 IOTLB miss 拖累。
> 业务最关键的那个 VF 绑到跟它同 NUMA 的核 + 同 group 的设备。

### 7.3 关闭 IOMMU 的后果

```text
禁止生产用
原因：
  - 一个 VM 可以通过 DMA 攻击读到 host 内存
  - 一个 VM 可以通过 DMA 攻击写到 host 内存
  - 经典的 VM escape 路径

性能影响：IOMMU 开 vs 关，性能差 < 5%（现代 NIC）
```

---

## 8. 安全配置：trust / spoof / VLAN / rate

### 8.1 trust 模式

```text
trust on:    VF 可配置自己的 MAC / VLAN / promisc / MTU
trust off (default):
              - VF 只能用 PF 指定的 MAC
              - VF 只能用 PF 指定的 VLAN
              - 收到 MAC 不匹配的包 = 丢弃
              - 收到 VLAN 不匹配的包 = 丢弃
```

```bash
# 默认 trust off
ip link set eth0 vf 0 trust on   # 允许 VM 自己改 MAC（生产慎用）
ip link set eth0 vf 0 trust off  # 强制由 host 配
```

### 8.2 spoof checking

```text
spoof on (default):
  - VM 发的包 MAC 必须等于 PF 配置的 MAC
  - 否则丢 + 计数器加

spoof off:
  - 不检查（VM 可以任意改源 MAC）
  - 用于特殊场景如 bonding / VRRP
```

```bash
ip link set eth0 vf 0 spoofchk on    # 默认就是 on
ip link set eth0 vf 0 spoofchk off
```

### 8.3 Rate limiting

```text
max_tx_rate:
  - 强制 VF 上限带宽
  - 0 = 不限
  - 例：max_tx_rate=1000 → 强制 1 Gbps

min_tx_rate (i40e/ice):
  - 保障最小带宽
  - 多个 VF 总和不能超过 uplink
  - 用于 SLA 业务
```

```bash
# 5G UPF 配 SLA
ip link set eth0 vf 0 min_tx_rate 500 max_tx_rate 8000   # 500Mbps - 8Gbps
ip link set eth0 vf 1 min_tx_rate 100 max_tx_rate 1000
```

### 8.4 VLAN 过滤

```text
VF VLAN tag (host 配):
  - 该 VF 只能进/出该 VLAN
  - 包带其他 VLAN 标签 = 丢弃

VLAN trunk:
  - 多个 VLAN 透传（需 trust on）
```

---

## 9. 与 vhost-user 的对比（决策表）

| 维度                  | SR-IOV VF                  | vhost-user                       |
| --------------------- | -------------------------- | -------------------------------- |
| **性能**              | 接近裸金属（高）           | 略低于裸金属（高）               |
| **CPU 占用**          | 低（硬件转发）             | 中（host 侧 OVS-DPDK/VPP 占用）  |
| **VM live migration** | 仅 mlx5 支持               | ✅ 通用                          |
| **安全隔离**          | 硬件级（IOMMU + firmware） | 软件级（vhost-user socket 权限） |
| **可观测性**          | 中（firmware 计数器）      | 高（OVS-DPDK 全栈可见）          |
| **VF ↔ VF 通信**      | 受限 / 需 switchdev        | 灵活（OVS 流表）                 |
| **适用业务**          | 单租户 VNF 强性能          | 多租户、频繁迁移、SDN 编排       |
| **代表场景**          | 5G UPF、vBNG、DPI          | 云内 NFV、SD-WAN、临时 VNF       |

**生产里的常见组合**：

```text
场景 A: 5G UPF 100Gbps（性能压倒一切）
  → 选 SR-IOV + mlx5 ConnectX-6/7
  → 透明 VF migration
  → DPDK 用户态 driver
  → 不需要 vhost-user

场景 B: 多租户 SD-WAN（灵活性第一）
  → 选 vhost-user + OVS-DPDK
  → 自由 live migration
  → 流表可观测、可编排
  → 性能略低但足够

场景 C: 混合（VNF 主流量 + 控制面 vhost-user）
  → 业务口：SR-IOV VF
  → 管理口：vhost-user
  → 同一 VM 两个数据口
```

---

## 10. 性能特征与调优

### 10.1 真实数据

```text
Intel XL710（i40e，4×10G）:
  - 1 个 PF 独占：9.4 Gbps
  - 8 个 VF 各 1 Gbps：8.0 Gbps 总
  - 单 VF pps 上限：~3.5 Mpps (64B 包)
  - 延迟（VM→wire）：~5-8 μs

Mellanox ConnectX-5（mlx5，1×100G）:
  - 1 个 PF 独占：98 Gbps
  - 16 个 VF 各 6G：~95 Gbps 总
  - 单 VF pps：~30 Mpps
  - 延迟：~2-4 μs

Intel E810（ice，2×100G）:
  - 单 PF：99 Gbps × 2
  - 32 个 VF：~190 Gbps 总
  - 单 VF pps：~30 Mpps
  - 延迟：~3-5 μs
```

### 10.2 调优点

| 优化                  | 命令 / 思路                                        |
| --------------------- | -------------------------------------------------- |
| **IRQ 亲和性**        | `echo 0,1,2,3 > /proc/irq/<vec>/smp_affinity`      |
| **NUMA 绑定**         | `numactl --cpunodebind=1`                          |
| **队列数 = lcore 数** | `-a <bdf>,queue-rx=N,queue-tx=N`                   |
| **RSS 配置**          | `ethtool -X <dev> equal N`（注意 VF 上不一定能改） |
| **关闭节能**          | BIOS 关闭 C-state、SpeedStep                       |
| **PCIe max payload**  | `setpci -s <bdf> 68.w` 看 max payload size         |
| **PCIe ACS**          | 关闭可减延迟但牺牲安全                             |

### 10.3 性能 vs 灵活性的现实选择

```text
                         性能 ↑
                          │
                          │       SR-IOV (mlx5)
                          │           ▲
                          │           │
       Hybrid ────────────┼───────────┘
                          │
                          │   SR-IOV (i40e/ice)
                          │
                          │
                          │
                          │
       vhost-user ────────┼──────────────────→ 灵活性 ↑
                          │
                          │
```

---

## 11. 排错清单

### 11.1 `sriov_numvfs` 写不进去

```bash
# 症状
$ echo 8 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs
bash: echo: write error: Cannot allocate memory

# 排查
1. BIOS: SR-IOV + ARI 是否都 Enable
2. NIC driver: modinfo i40e | grep -i sriov
3. dmesg | grep -i 'sriov\|vf'
   # 看是否有 "failed to enable VFs" 等提示
4. IOMMU 是否开启（i40e/ice 必须）
5. max_vfs 是不是超过 NIC 型号上限
```

### 11.2 VM 看不到 VF

```bash
# 1. libvirt 启动失败：no such device
virsh start vm
error: Failed to start domain vm
error: internal error: qemu unexpectedly closed the monitor

# 原因 1：VF 没绑到 vfio-pci
$ dpdk-devbind.py -s
0000:3d:02.0 'I40E' 'I40E' if=eth0 drv=i40e
# ← 还是 i40e，没绑到 vfio-pci
$ dpdk-devbind.py -b vfio-pci 0000:3d:02.0

# 原因 2：IOMMU 没开
# 原因 3：ACS 没开
```

### 11.3 VF 性能低

```bash
# 1. 看实际速率
ethtool -S <vf-name> | grep -E 'rx_packets|tx_packets|drop'

# 2. 看 NUMA
cat /sys/class/net/<vf-name>/device/numa_node
# 0 = node 0, -1 = 没绑

# 3. 看 PCIe 协商速率
lspci -vvvs 0000:3d:00.0 | grep -i speed
# Speed 8GT/s, Width x8 = 正常
# Speed 2.5GT/s, Width x1 = 性能严重不足！

# 4. 看队列
ethtool -l <vf-name>
# 当前 RX 队列数 / 最大
```

### 11.4 VF 间不能通信

```bash
# 检查 switchdev 模式
devlink dev eswitch show pci/0000:03:00.0
# switchdev: enabled / legacy

# legacy 模式 + 多 VF：默认隔离
# switchdev 模式 + 配 steering：可以互通
```

### 11.5 VF 莫名 down

```bash
# 1. 看 dmesg
dmesg | grep -i 'vf\|i40e\|ice\|mlx5' | tail -20

# 2. 看 NIC 错误计数器
mlxlink (mlx5 工具)
# or
ethtool --show-priv-flags <pf>
# 找 link-down、fatal-error 等私有 flag
```

---

## 12. 速查卡片

### 12.1 命令速查

```bash
# PF / VF 信息
lspci | grep -i 'ethernet\|network'
lspci -vvv -s 0000:3d:00.0           # 看 SR-IOV cap
lspci -k -s 0000:3d:02.0             # 看 VF 的 kernel driver
cat /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs
cat /sys/bus/pci/devices/0000:3d:00.0/sriov_totalvfs

# 创建/销毁 VF
echo 8 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs
echo 0 > /sys/bus/pci/devices/0000:3d:00.0/sriov_numvfs

# 找 VF 的 BDF
ls -l /sys/bus/pci/devices/0000:3d:00.0/virtfn0
# -> ../0000:3d:02.0

# VF 安全
ip link set <pf> vf <N> mac <mac>
ip link set <pf> vf <N> vlan <vlan>
ip link set <pf> vf <N> spoofchk on
ip link set <pf> vf <N> trust on
ip link set <pf> vf <N> min_tx_rate 1000
ip link set <pf> vf <N> max_tx_rate 8000
ip link set <pf> vf <N> state enable

# DPDK 视角
dpdk-devbind.py -s
dpdk-devbind.py -b vfio-pci 0000:3d:02.0
dpdk-app -l 0-7 -n 4 -- -a 0000:3d:02.0,queue-rx=4,queue-tx=4

# switchdev (mlx5)
devlink dev eswitch set pci/0000:03:00.0 mode switchdev
ip link show  # 看 representor

# migration
lspci -vvv -s 0000:03:00.4 | grep -i migrat
qemu ... -device vfio-pci,host=0000:03:00.4
```

### 12.2 决策速查

```text
需求                          推荐
─────────────────────────────────────
单租户 VNF 极致性能           SR-IOV (mlx5) + DPDK
多租户 SDN 灵活调度           vhost-user + OVS-DPDK
5G UPF (latency critical)     SR-IOV (mlx5) + DPDK + transparent migration
NFV GW (流量均衡)             vhost-user + OVS-DPDK
4G EPC (老架构)               SR-IOV (i40e) + DPDK
NFV GW + 频繁扩容             vhost-user (DPDK 性能足够)
```

---

## 13. 总结

```text
SR-IOV 是一套“硬件 + firmware + 驱动”三位一体的规范：
  - 硬件：NIC 内部 embedded switch + 资源切分
  - firmware：VF 状态机 + scheduling + 计数器
  - 驱动：PF 驱动的控制平面 + VF 驱动的数据平面

现代 NFV 的实际选择：
  - 极致性能 / 强实时 → SR-IOV (mlx5)
  - 多租户 / 灵活迁移 → vhost-user
  - 5G UPF 特殊场景 → mlx5 SR-IOV (唯一同时满足性能和透明迁移的方案)

机制核心：硬件切分 + 固件调度 + 驱动控制
```

**核心要点**：

1. **VF 真实存在**：不是软件模拟，lspci 能看到，跟普通 PCI 设备一样
2. **PF 驱动是唯一控制入口**：MAC / VLAN / rate / trust 都从 PF 下发
3. **Embedded switch 是隔离基础**：VF ↔ uplink 默认隔离，VF ↔ VF 默认隔离
4. **i40e/ice vs mlx5**：
   - i40e/ice：稳定但不支持 VF live migration
   - mlx5：支持 switchdev + vDPA + transparent VF migration
5. **IOMMU 是必选项**：生产环境不开 IOMMU = 安全自杀
6. **DPDK 看 VF 跟看 PF 一样**：`rte_eth_dev_*` API 完全通用

---

## 参考资源

- [PCI-SIG SR-IOV 规范](https://pcisig.com/specifications)
- [Intel X710 / E810 配置手册](https://www.intel.com/content/www/us/en/docs/network/ethernet/controllers/100-gbE.html)
- [Mellanox OFED / mlx5 文档](https://docs.nvidia.com/networking/display/mlnxofedv461000/)
- [Linux VFIO](https://www.kernel.org/doc/Documentation/driver-api/vfio.rst)
- [DPDK linux_gsg](https://doc.dpdk.org/guides/linux_gsg/)
- [Kernel switchdev 文档](https://docs.kernel.org/networking/switchdev.html)
- [devlink 文档](https://man7.org/linux/man-pages/man8/devlink.8.html)
- [SR-IOV 与 vhost-user 对比 (Red Hat)](https://access.redhat.com/articles/5322931)
