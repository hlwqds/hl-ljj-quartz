---
title: "RDMA 第二十六章：SR-IOV——单根 I/O 虚拟化与 RDMA"
date: 2026-04-13
tags: [rdma, sriov, virtualization, vf, pf, virtual-function, pci-passthrough, mellanox, roce]
description: "深入解析 SR-IOV 技术原理：物理函数 (PF) 与虚拟函数 (VF)、Mellanox 网卡 SR-IOV 配置、RDM A VF 的 CNI 集成、以及性能与安全的权衡。"
---

> [!abstract] 核心要点
> SR-IOV（Single Root I/O Virtualization）是 RDMA 网卡虚拟化的主流方案，通过将物理网卡虚拟成多个 VF，让每个容器或 VM 获得独立的 RDMA 能力，同时保持硬件级的隔离和性能。本章详解 SR-IOV 原理、Mellanox/Intel 网卡配置、以及 VF 在 Kubernetes 中的使用。

---

## 1. SR-IOV 概述

### 1.1 为什么需要 SR-IOV

传统 PCIe Passthrough 将整个网卡分配给一个 VM/容器，但 AI/HPC 环境中需要同时运行多个容器，每个都需要 RDMA 能力：

```
PCIe Passthrough vs SR-IOV：

  PCIe Passthrough (单租户):
    ┌────────────────────────────────────────────┐
    │  Host                                     │
    │  ┌──────────────────────────────────────┐  │
    │  │  Physical NIC (PF)                   │  │
    │  │  ████████████████████████████████     │  │
    │  │  整个网卡分配给一个 VM/容器           │  │
    │  └──────────────────────────────────────┘  │
    └────────────────────────────────────────────┘

  SR-IOV (多租户):
    ┌────────────────────────────────────────────┐
    │  Host                                     │
    │  ┌──────────────────────────────────────┐  │
    │  │  Physical NIC (PF)                   │  │
    │  │  ┌────┬────┬────┬────┬────┬────┐   │  │
    │  │  VF0 │ VF1 │ VF2 │ VF3 │ VF4 │ VF5 │   │  │
    │  │  ███  ███  ███  ███  ███  ███     │  │
    │  │  VM1  VM2  VM3  Cont1 Cont2 Cont3    │  │
    │  └────┴────┴────┴────┴────┴────┘       │  │
    │  每个 VF 独立分配，硬件隔离              │  │
    │  └──────────────────────────────────────┘  │
    └────────────────────────────────────────────┘

  关键差异：
    - Passthrough: 1:1 映射，资源利用率低
    - SR-IOV: 1:N 映射，支持多租户共享
```

### 1.2 SR-IOV 核心概念

```
SR-IOV 核心概念：

  PF (Physical Function):
    - 物理网卡上的主要功能
    - 拥有完整的 PCIe 配置空间
    - 负责管理 VF 的创建和配置
    - 也可以直接用于 host 本身的网络

  VF (Virtual Function):
    - 由 PF 虚拟化出来的轻量级功能
    - 只有精简的 PCIe 配置空间
    - 共享物理网卡的带宽和硬件引擎
    - 对 VM/容器表现为独立网卡

  ARI (Alternative Routing ID):
    - SR-IOV 设备使用 ARI 扩展
    - 允许多个 VF 共享同一个 Bus
    - VF 使用不同的 Function Number
```

### 1.3 SR-IOV 与 RDMA 的关系

RDMA 网卡（ConnectX 系列）原生支持 SR-IOV：

```
Mellanox ConnectX SR-IOV 架构：

  ┌──────────────────────────────────────────────────────────────────┐
  │                    ConnectX-6/7 Physical NIC                     │
  │  ┌──────────────────────────────────────────────────────────┐   │
  │  │  PF0 (Physical Function)                                  │   │
  │  │  - 完整的 RDMA 功能                                        │   │
  │  │  - RoCE/IB 协议处理                                        │   │
  │  │  - QP/CQ/MR 资源                                          │   │
  │  │  - 管理 VF                                                │   │
  │  │  ├── VF0 (RDMA-enabled)                                   │   │
  │  │  ├── VF1 (RDMA-enabled)                                   │   │
  │  │  ├── VF2 (RDMA-enabled)                                   │   │
  │  │  └── VF3 (RDMA-enabled) ← 每个 VF 都有独立                 │   │
  │  │      ├── GID 表                                            │   │
  │  │      ├── QP 资源池                                         │   │
  │  │      └── 安全策略                                          │   │
  │  └──────────────────────────────────────────────────────────┘   │
  │                                                                  │
  │  ┌──────────────────────────────────────────────────────────┐   │
  │  │  PF1 (Physical Function) - 第二张网卡                    │   │
  │  │  └── ...                                                  │   │
  │  └──────────────────────────────────────────────────────────┘   │
  └──────────────────────────────────────────────────────────────────┘
```

---

## 2. Mellanox SR-IOV 配置

### 2.1 BIOS 和 Linux 配置

SR-IOV 需要 BIOS 和 OS 层面的支持：

```bash
# 1. 确认 BIOS 中 SR-IOV 已启用
# 不同服务器厂商有不同配置方式，通常在 PCIe 设置中找到

# 2. 确认 Linux 内核支持 SR-IOV
$ lspci | grep -i mellanox
87:00.0 Infiniband controller: Mellanox Technologies MT28908 Family [ConnectX-6]
87:00.1 Infiniband controller: Mellanox Technologies MT28908 Family [ConnectX-6]

# 3. 加载 SR-IOV 内核模块
modprobe mlx5_core
modprobe mlx5_ib

# 4. 确认 SR-IOV 支持
$ cat /sys/bus/pci/devices/0000:87:00.0/sriov_totalvfs
16  # 该设备最多支持 16 个 VF

# 5. 启用 SR-IOV (需要 root)
echo 8 > /sys/bus/pci/devices/0000:87:00.0/sriov_numvfs

# 6. 查看 VF
$ lspci | grep -i "Virtual Function"
87:00.2 Virtual function
87:00.3 Virtual function
87:00.4 Virtual function
...
```

### 2.2 创建 RDMA 启用的 VF

```bash
# Mellanox 网卡 SR-IOV 配置脚本
#!/bin/bash
# setup_sriov.sh

set -e

PCI_DEV="0000:87:00.0"  # ConnectX-6 PCI 地址
NUM_VFS=8

# 清除现有 VF
echo 0 > /sys/bus/pci/devices/${PCI_DEV}/sriov_numvfs

# 设置 VF 数量
echo ${NUM_VFS} > /sys/bus/pci/devices/${PCI_DEV}/sriov_numvfs

# 配置每个 VF 的 RDMA 能力
for i in $(seq 0 $((NUM_VFS-1))); do
    VF_PATH="/sys/bus/pci/devices/${PCI_DEV}/virtfn${i}"
    
    # 启用 RDMA
    echo 1 > ${VF_PATH}/rdma/enable
    
    # 设置带宽限制（可选）
    #echo 25000 > ${VF_PATH}/max_tx_rate  # 25 Gbps
done

# 验证 VF 创建
$ ls -la /sys/class/infiniband/
mlx5_0  mlx5_1  (PF)
mlx5_2  mlx5_3 ... (VF)

# 查看 VF 的 GID
$ ibv_devices
    device                 board_guid
    mlx5_0                0000cemi0ff00000    # PF
    mlx5_2                0000cemi0ff00002    # VF
    ...
```

### 2.3 持久化 SR-IOV 配置

```bash
# /etc/systemd/system/sriov-setup.service
[Unit]
Description=SR-IOV Configuration
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/setup_sriov.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

# 或者使用 udev 规则
# /etc/udev/rules.d/81-sriov.rules
ACTION=="add", SUBSYSTEM=="pci", \
    ENV{PCI_ADDRESS}=="0000:87:00.0", \
    ATTR{sriov_numvfs}="8"
```

### 2.4 Mellanox Firmware 配置

通过 mlxconfig 或 UFM 配置 SR-IOV 参数：

```bash
# 查看当前 SR-IOV 配置
$ mstflint -d 87:00.0 qos show

# 启用 SR-IOV (Firmware 级别)
$ mlxconfig -d 87:00.0 set SRIOV_EN=1 NUM_OF_VFS=8

# 配置 VF 的 QoS
$ mlxconfig -d 87:00.0 set VF_MAX_RATE=25  # 每个 VF 最大 25 Gbps
$ mlxconfig -d 87:00.0 set VF_BW_SWT_BURST=0  # 无限制突发

# 重启驱动生效
$ modprobe -r mlx5_core && modprobe mlx5_core
```

---

## 3. VF 之间的 RDMA 通信

### 3.1 VF 的 GID 分配

每个 VF 有独立的 GID 表：

```bash
# 查看 VF 的 GID
$ ibv_devices
    device                 board_guid
    mlx5_0                0000cemi0ff00000    # PF
    mlx5_2                0000cemi0ff00002    # VF0
    mlx5_3                0000cemi0ff00003    # VF1

# 查看 VF0 的 GID
$ gidformat show -d mlx5_2
DEV     PORT   INDEX   GID
mlx5_2  1      8       fe80:0000:0000:0000:7cfe:4503:ff00:0e02

# VF 之间的通信
# VF0 的 GID: fe80:0000:0000:0000:7cfe:4503:ff00:0e02
# VF1 的 GID: fe80:0000:0000:0000:7cfe:4503:ff00:0e03
```

### 3.2 VF 通信架构

```
VF 到 VF 通信（同一主机）：

  ┌────────────────────────────────────────────────────────────────┐
  │                          Host                                  │
  │  ┌────────────────────────────────────────────────────────┐    │
  │  │  ConnectX-6 (PF)                                        │    │
  │  │  ┌────────┐  ┌────────┐  ┌────────┐                   │    │
  │  │  │  VF0   │  │  VF1   │  │  VF2   │  ...               │    │
  │  │  │ GID:A  │  │ GID:B  │  │ GID:C  │                   │    │
  │  │  └────┬───┘  └────┬───┘  └────┬───┘                   │    │
  │  │       │           │           │                       │    │
  │  │       ▼           ▼           ▼                       │    │
  │  │       └───────────┴───────────┘                       │    │
  │  │                   │                                     │    │
  │  │            HW Switch (on-chip)                         │    │
  │  │                   │                                     │    │
  │  │                   ▼                                     │    │
  │  │            External Network                            │    │
  │  └────────────────────────────────────────────────────────┘    │
  └────────────────────────────────────────────────────────────────┘

  注意：
    - 同一主机上的 VF 可以通过芯片内交换直接通信
    - 也可以通过外部交换机路由
```

### 3.3 配置示例：VF 之间 RDMA 测试

```bash
# 在 VF0 的容器内
# kubectl exec -it rdma-vf0-pod -- bash

# 测试 RDMA 连接
root@rdma-vf0-pod:~# ibv_rc_pingpong -d mlx5_2 -g 0
# 使用 VF0 的设备

# 在 VF1 的容器内
# kubectl exec -it rdma-vf1-pod -- bash

# 从 VF1 连接到 VF0
root@rdma-vf1-pod:~# ibv_rc_pingpong -d mlx5_3 -g 0 <VF0-IP>

# 使用 perftest 测试带宽
root@rdma-vf0-pod:~# perftest -d mlx5_2 -z
root@rdma-vf1-pod:~# perftest -d mlx5_3 -z <VF0-IP>
```

---

## 4. Kubernetes 中的 SR-IOV VF

### 4.1 SriovNetworkNodePolicy CRD

```yaml
# sriov-network-node-policy.yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-policy
  namespace: openshift-sriov-network-operator
spec:
  nodeSelector:
    feature.node.kubernetes.io/rdma: "true"
  resourceName: rdma
  numVfs: 8
  nicSelector:
    vendor: "15b3"      # Mellanox
    deviceID: "101e"    # ConnectX-6
    pfNames: ["enp135s0f0"]  # PF 名称
  vfPolicy:
    resources:
      - name: rdma
        max_tx_rate: "25000"
        min_tx_rate: "5000"
   SpoofChk: off
    Trust: on
    Rdma: true   # 启用 RDMA
```

```bash
# 应用配置
kubectl apply -f sriov-network-node-policy.yaml

# 验证 VF 创建
$ kubectl describe node <node> | grep -A5 sriov
  sriov.networking.openshift.io/rdma: "8"
```

### 4.2 SriovNetwork CRD

```yaml
# sriov-network.yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-sriov-net
  namespace: openshift-sriov-network-operator
spec:
  networkNamespace: default
  resourceName: rdma
  capabilities: '{"rdma": true}'
  ipam: '{"type":"static","addresses":[{"address":"192.168.100.10/24"}]}'
```

### 4.3 在 Pod 中使用 VF

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sriov-rdma-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-sriov-net
spec:
  containers:
  - name: main
    image: rdma-hpc:latest
    resources:
      limits:
        rdma/rdma: "1"
    securityContext:
      capabilities:
        add: ["IPC_LOCK", "NET_RAW"]
    env:
    - name: RDMA_VF_DEVICE
      value: "/dev/infiniband/uverbs0"
```

### 4.4 多网卡 VF 配置

```yaml
# 多网卡 SR-IOV 配置
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: multi-rdma-nic
spec:
  nodeSelector:
    feature.node.kubernetes.io/rdma: "true"
  resourceName: mlx5_0
  numVfs: 4
  nicSelector:
    pfNames: ["enp135s0f0"]
  vfPolicy:
    Rdma: true

---
# 第二张网卡
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: multi-rdma-nic2
spec:
  nodeSelector:
    feature.node.kubernetes.io/rdma: "true"
  resourceName: mlx5_1
  numVfs: 4
  nicSelector:
    pfNames: ["enp136s0f0"]
  vfPolicy:
    Rdma: true
```

```yaml
# Pod 使用多 VF
apiVersion: v1
kind: Pod
metadata:
  name: multi-nic-rdma-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [{"name": "mlx5_0-rdma", "interface": "netrdma0"},
       {"name": "mlx5_1-rdma", "interface": "netrdma1"}]
spec:
  containers:
  - name: main
    image: nvidia/cuda:11.8-runtime-ubi8
    resources:
      limits:
        rdma/mlx5_0: "1"
        rdma/mlx5_1: "1"
        nvidia.com/gpu: 4
    env:
    - name: NCCL_IB_HCA
      value: "mlx5_0,mlx5_1"
```

---

## 5. VF 的 MAC 和 VLAN 配置

### 5.1 VF MAC 地址配置

每个 VF 可以有独立的 MAC 地址：

```bash
# 查看 VF 的 MAC
$ cat /sys/class/net/enp135s0f0/device/virtfn0/address
ec:0d:9a:11:22:33

# 为 VF 设置 MAC（需要 PF 在 Trust 模式）
ip link set enp135s0f0 vf 0 mac ec:0d:9a:11:22:44

# 在 Kubernetes 中通过 SriovNetworkNodePolicy 配置
```

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-vf-mac
spec:
  resourceName: rdma
  vfPolicy:
    mac: "ec:0d:9a:11:22:44"  # 固定 MAC
```

### 5.2 VF VLAN 配置

VF 支持 802.1Q VLAN 标记：

```bash
# 设置 VF VLAN
# 需要交换机侧对应配置
ip link set enp135s0f0 vf 0 vlan 100

# 设置 QoS/优先级
ip link set enp135s0f0 vf 0 vlan 100 qos 3

# 验证
$ ip link show enp135s0f0
  vf 0 MAC: ec:0d:9a:11:22:44, VLAN ID: 100, QoS: 3
```

```yaml
# Kubernetes 配置 VLAN
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetwork
metadata:
  name: rdma-vlan-net
spec:
  resourceName: rdma
  vlan: 100
  capabilities: '{"rdma": true}'
```

### 5.3  VF 速率限制

```bash
# 设置 VF 最大速率 (单位 Mbps)
ip link set enp135s0f0 vf 0 max_tx_rate 25000  # 25 Gbps

# 设置最小速率（保证带宽）
ip link set enp135s0f0 vf 0 min_tx_rate 10000  # 10 Gbps

# 查看当前配置
$ cat /sys/class/net/enp135s0f0/device/virtfn0/max_tx_rate
25000
```

```yaml
# Kubernetes 中的 QoS 配置
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-qos-policy
spec:
  resourceName: rdma
  vfPolicy:
    max_tx_rate: 25000    # 25 Gbps
    min_tx_rate: 10000    # 10 Gbps
    Rdma: true
```

---

## 6. 安全考虑

### 6.1 VF 隔离

SR-IOV 提供了硬件级的隔离，但需要注意：

```
VF 安全隔离层次：

  1. PCIe 层面
     - 每个 VF 有独立的 PCIe 配置空间
     - 无法访问其他 VF 的 PCIe 流量
     - 硬件级别的 DMA 隔离

  2. RDMA 层面
     - 每个 VF 有独立的 GID
     - 密钥 (lkey/rkey) 隔离
     - QP 资源独立

  3. 网络层面
     - VF MAC/VLAN 隔离
     - 需要交换机侧 ACL 配合
     - 缺少 Hypervisor 的虚拟防火墙

  安全风险：
    ⚠️ VF 可以直接发送任意 MAC/IP 包
    ⚠️ VF 可以加入任何多播组
    ⚠️ 交换机 ACL 配置复杂，可能有遗漏
```

### 6.2 Trust 模式

默认情况下 VF 不能更改 MAC 地址。通过设置 Trust 模式可以允许：

```bash
# PF 侧设置 VF 为 Trust 模式（允许更改 MAC）
ip link set enp135s0f0 vf 0 trust on

# 在 Kubernetes 中
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-trust-policy
spec:
  resourceName: rdma
  vfPolicy:
    Trust: on  # 允许 VF 设置自定义 MAC
    Rdma: true
```

### 6.3 Spoofcheck

防止 VF 发送伪造的 MAC 地址：

```bash
# 启用 spoofcheck（默认）
ip link set enp135s0f0 vf 0 spoofchk on

# 禁用 spoofcheck（危险，仅在必要时使用）
ip link set enp135s0f0 vf 0 spoofchk off
```

```yaml
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-spoofcheck-off
spec:
  resourceName: rdma
  vfPolicy:
    SpoofChk: off  # 仅在需要自定义 MAC 时禁用
    Rdma: true
```

---

## 7. 性能与调优

### 7.1 VF vs PF 性能对比

```
VF vs PF 性能（ConnectX-6 100Gbps）：

  测试           PF        VF        差异
  ──────────────────────────────────────────
  延迟 (64B)     3.1 μs    3.2 μs    ~3%
  带宽 (128B)    98 Gbps   96 Gbps   ~2%
  IOPS (4B)      2.1M     2.0M      ~5%

  结论：VF 引入的开销极小，对于 RDMA 性能几乎没有影响
```

### 7.2 VF 数量与性能

VF 数量增加会导致共享资源竞争：

```bash
# 测试不同 VF 数量下的性能
# 1 VF (独占) vs 8 VF (共享)
# 结果显示：
#   - 1 VF: 98 Gbps 带宽，3.1 μs 延迟
#   - 4 VF: 95 Gbps 带宽，3.2 μs 延迟 (每 VF 约 24 Gbps)
#   - 8 VF: 90 Gbps 带宽，3.5 μs 延迟 (每 VF 约 11 Gbps)

# 建议：每个 VF 应保留足够的带宽预算
# 对于 AI 训练，建议每 GPU 分配 1 个独立 VF
```

### 7.3 VF 调优参数

```bash
# 优化 VF 的 RDMA 参数
# 适用于 Mellanox ConnectX

# 1. 启用 QoS
ethtool --set-priv-flags eth0 roce_adaptive_rate_arb on

# 2. 设置 QoS 权重（公平调度）
# 需要 mlnx_qos 或 ethtool
ethtool --set-rx-classes eth0 flowtype 0x10 weight 25  # RDMA 流量高权重

# 3. 调整 interrupt coalescing
ethtool -C eth0 rx-usecs 0 tx-usecs 0  # 降低延迟，禁用中断合并

# 4. 调整 TX/RX ring size
ethtool -G eth0 rx 4096 tx 4096  # 增大 ring 减少丢包

# 5. 启用 flow control
ethtool -A eth0 rx on tx on  # 对 RDMA 重要
```

### 7.4 NUMA 亲和性

VF 的 PCIe 位置影响性能：

```bash
# 查看 VF 的 NUMA 位置
$ cat /sys/class/net/enp135s0f0/device/virtfn0/numa_node
1

# 确保容器进程使用正确的 NUMA
# 在 Pod spec 中设置
spec:
  containers:
  - name: main
    resources:
      limits:
        rdma/rdma: "1"
    resources:
      limits:
        memory: "64Gi"
      requests:
        memory: "64Gi"
  # 使用 topology manager
  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/numa
    labelSelector:
      matchLabels:
        app: rdma-workload
```

---

## 8. 故障排除

### 8.1 常见问题

```
SR-IOV RDMA 问题排查：

  问题 1: VF 创建失败
  原因：
    - BIOS 未启用 SR-IOV
    - 内核不支持
    - 驱动版本不匹配
  解决：
    $ dmesg | grep -i sriov
    $ lspci -vvv | grep -i sriov
    检查 BIOS 设置

  问题 2: VF 不支持 RDMA
  原因：
    - Firmware 未启用 SR-IOV RDMA
    - mlxconfig 未设置 SRIOV_EN=1
  解决：
    $ mlxconfig -d 87:00.0 get | grep SRIOV
    SRIOV_EN=True(N/A)  # 应该是 True
    $ mlxconfig -d 87:00.0 set SRIOV_EN=1 NUM_OF_VFS=8

  问题 3: VF 之间无法 RDMA 通信
  原因：
    - 交换机未配置对应 VLAN
    - PFC 未在所有端口启用
  解决：
    $ ibv_rc_pingpong -d mlx5_2 -g 0 <remote-gid>
    检查两端 GID 是否在同 一 VLAN

  问题 4: Pod 无法获取 VF
  原因：
    - SriovNetworkNodePolicy 未正确应用
    - 资源不足（VF 数量耗尽）
  解决：
    $ kubectl describe node <node> | grep sriov
    $ kubectl get sriovnetworknodestates -A
```

### 8.2 验证命令

```bash
# 1. 确认 SR-IOV 已启用
$ cat /sys/bus/pci/devices/0000:87:00.0/sriov_numvfs
8

# 2. 查看所有 VF
$ ls -la /sys/class/infiniband/
mlx5_0 (PF)
mlx5_2 (VF0)
mlx5_3 (VF1)
mlx5_4 (VF2)
...

# 3. 检查 VF 的 RDMA 能力
$ ibv_devinfo -d mlx5_2
hca_type: MT28908
board_id: MT28908
phys_port_cnt: 1

# 4. 测试 VF 基本连通性
$ ibv_devinfo -d mlx5_2 | grep node_guid
node_guid: 0000cemi0ff00002

# 5. 检查 VF 的 GID
$ gidformat show -d mlx5_2

# 6. 端到端测试（两台主机各一个 VF）
# Host A: kubectl exec -it pod-a -- ibv_rc_pingpong -d mlx5_2 -g 0
# Host B: kubectl exec -it pod-b -- ibv_rc_pingpong -d mlx5_3 -g 0 <A's-gid>
```

---

## 9. 小结

```
本章要点：

  1. SR-IOV 通过将物理网卡虚拟成多个 VF，支持多容器/VM 共享同一物理网卡

  2. Mellanox ConnectX 系列原生支持 SR-IOV，每个 VF 都有独立的 RDMA 能力

  3. VF 与 PF 性能差异极小（< 5%），适合高性能 RDMA 场景

  4. Kubernetes 通过 SriovNetworkNodePolicy CRD 配置 VF，SriovNetwork 分配给 Pod

  5. VF 安全需要配置 SpoofChk、Trust 模式和交换机 ACL

  6. VF 数量增加会导致资源竞争，建议 AI 训练场景每 GPU 配 1 个 VF

  7. NUMA 亲和性和 QoS 配置是生产环境的重要调优项
```