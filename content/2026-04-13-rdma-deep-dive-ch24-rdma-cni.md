---
title: "RDMA 第二十四章：RDMA CNI——容器网络接口"
date: 2026-04-13
tags: [rdma, cni, container, kubernetes, ipoib, host-device, macvlan, ipvlan]
description: "详解 RDMA CNI 插件体系：IPoIB、host-device、macvlan、ipvlan 四种模式的工作原理、配置方法、性能对比，以及多网卡场景下的 RDMA 网络设计。"
---

> [!abstract] 核心要点
> RDMA CNI 是 Kubernetes 环境下暴露 RDMA 能力的标准接口。本章深入分析四种主流 RDMA CNI 模式——IPoIB、host-device、macvlan、ipvlan——的工作原理、配置步骤、性能特性，以及在不同 AI/HPC 场景下的选型建议。

---

## 1. 为什么容器需要 RDMA CNI

### 1.1 传统 CNI 的局限性

标准 Kubernetes CNI（flannel、calico、cilium）设计目标是为容器提供 IP 连通性，完全不考虑 RDMA 所需的高带宽和超低延迟：

```
传统 CNI 数据路径：

  Container A → veth pair → docker0/bridge → eth0 → Physical NIC → Network
                      ▲
                      └── 每次都经过内核协议栈，至少 10-50 μs 延迟

RDMA 要求的数据路径：

  Container A → 直接访问 HCA → Network
              └── 绕过内核，延迟 < 5 μs
```

### 1.2 RDMA CNI 的核心挑战

将 RDMA 能力透传给容器面临四个核心挑战：

```
RDMA CNI 四大挑战：

  1. 设备透传 (Device Passthrough)
     - HCA 本身是 PCIe 设备，需要透传给容器
     - 需要 SR-IOV 或 device plugin 机制

  2. GID/LID 地址管理
     - RDMA 使用 GID (IPv6 格式) 作为通信地址
     - 容器内需要能看到正确的 GID

  3. 内存注册
     - 容器进程需要注册自己的内存供 RDMA 访问
     - 需要大页内存支持

  4. 资源隔离
     - 多个容器共享物理网卡时的资源分配
     - QoS 保障
```

### 1.3 CNI 规范与 RDMA 扩展

CNI（Container Network Interface）规范定义了容器网络的标准化接口。RDMA CNI 在此基础上添加了额外的设备发现和配置能力：

```bash
# CNI 标准操作
# ADD: 将容器接入网络，返回 IP、MAC、interface name
# DEL: 将容器从网络移除
# CHECK: 检查网络配置是否正确

# RDMA CNI 扩展
# 除了标准返回值，还需要返回：
#   - RDMA device path (/dev/infiniband/uverbsX)
#   - GID index
#   - MTU (最大传输单元)
```

---

## 2. IPoIB 模式

### 2.1 IPoIB 工作原理

IPoIB（IP over InfiniBand）是 RDMA 最传统的网络模式之一。它在 IB 传输层之上封装标准 IP，使得传统 TCP/IP 应用无需修改即可在 RDMA 网络上运行：

```
IPoIB 协议栈：

  Application (TCP/UDP Socket)
        ↓
  Kernel IP Stack
        ↓
  IPoIB Driver (ib_ipoib)
        ↓
  IB Transport Layer (CM/UD/RC)
        ↓
  IB Network Layer (LID/GID)
        ↓
  IB Link Layer
        ↓
  HCA (ConnectX)
```

在容器场景中，IPoIB 通过创建 IPoIB 虚拟设备（子接口）实现：

```bash
# 在主机上创建 IPoIB 子接口
# 假设物理 IB 设备为 mlx5_0

# 1. 查看当前 IB 设备
$ ibdev2netdev
mlx5_0       ==> eth0        (Up)
mlx5_1       ==> eth1        (Up)

# 2. 创建 IPoIB 子接口（用于 RoCE）
# IPoIB 支持两种模式：datagram（默认）和 connected
ip link add ib0 type ipoib mode connected
ip addr add 192.168.100.10/24 dev ib0
ip link set ib0 up

# 3. 查看 IPoIB 设备信息
$ ip link show ib0
9: ib0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 65520 qdisc pfifo_fast
    link/infiniband 80:00:00:48:fe:80:00:00:00:00:00:00:00:00:00:00:00:00:00:00
    qlen 256
    inet 192.168.100.10/24 scope global ib0

# 4. 获取 GID
$ gidformat show
DEV     PORT   INDEX   GID
mlx5_0  1      8       fe80:0000:0000:0000:7cfe:4503:ff00:0e0c
```

### 2.2 Kubernetes IPoIB CNI 配置

IPoIB CNI 的典型实现是 `host-device` 模式的变体，将主机的 IPoIB 设备透传给容器：

```json
// ipoib.conf - IPoIB CNI 配置文件
{
  "cniVersion": "0.3.1",
  "name": "ipoib-network",
  "type": "host-device",
  "device": "ib0",
  "ipam": {
    "type": "static",
    "addresses": [
      {
        "address": "192.168.100.100/24",
        "gateway": "192.168.100.1"
      }
    ]
  }
}
```

```bash
# 部署步骤
# 1. 在所有 Node 上预先创建 IPoIB 设备
cat <<EOF > /etc/systemd/system/create-ipoib.service
[Unit]
Description=Create IPoIB device
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link add ib0 type ipoib mode connected
ExecStart=/usr/sbin/ip addr add 192.168.100.0/24 dev ib0
ExecStart=/usr/sbin/ip link set ib0 up
ExecStart=/usr/sbin/ip link set ib0 mtu 65520

[Install]
WantedBy=multi-user.target
EOF

systemctl enable create-ipoib

# 2. 配置 CNI（将 ib0 透传给容器）
# 使用 host-device CNI 将 ib0 分配给容器

# 3. 验证容器内 RDMA 可用性
# kubectl exec -it rdma-app -- bash
# ibstat
```

### 2.3 IPoIB 的局限性

```
IPoIB 主要缺点：

  1. 性能损失
     - IP 封装/解封开销
     - 无法利用 RDMA 的零拷贝优势
     - 延迟比原生 RDMA 高 2-3x

  2. MTU 限制
     - IB MTU 最高 65520 bytes
     - IPoIB 封装后实际 payload 更小
     - 通常需要 4096 以下以避免分片

  3. 广播/多播支持受限
     - IPoIB 基于 IB 多播，但效率不高
     - 不适合大规模集群发现

  4. 无法使用 verbs API 直接通信
     - 应用仍通过 socket 接口
     - 失去了 RDMA Send/Recv 能力
```

---

## 3. host-device 模式

### 3.1 工作原理

`host-device` CNI 将主机上的物理网卡（或已创建的子设备）直接透传给容器，使容器获得对网卡的直接访问权限：

```
host-device CNI 数据路径：

  Container A
  ┌────────────┐
  │ eth0       │ ← 分配的 VF 或子设备
  └─────┬──────┘
        │ (直接映射到 host 的物理网卡或 VF)
        ▼
  Host Physical NIC / VF
        │
        ▼
      HCA → Network
```

### 3.2 配置示例

```json
// host-device-rdma.conf
{
  "cniVersion": "0.3.1",
  "name": "rdma-host-device",
  "type": "host-device",
  "device": "mlx5_0",
  "ipam": {
    "type": "dhcp"
  },
  "rdma": {
    " devices": ["/dev/infiniband/uverbs0"],
    "hcaClass": "net_rdma"
  }
}
```

```bash
# 步骤 1: 确认设备存在
$ ls -la /dev/infiniband/
total 0
drwxr-xr-x  1 root root  120 Apr 14 10:00 .
drwxr-xr-x  1 root root 4096 Apr 14 10:00 ..
crw-------  1 root root 230,   0 Apr 14 10:00 iser
crw-------  1 root root 230,  16 Apr 14 10:00 issm
crw-rw-rw-  1 root root 230,  32 Apr 14 10:00 uverbs0
crw-rw-rw-  1 root root 230,  48 Apr 14 10:00 uverbs1
crw-------  2 root root 230, 256 Apr 14 10:00
crw-------  1 root root 230, 272 Apr 14 10:00 umad0
crw-------  1 root root 230, 288 Apr 14 10:00 umad1

# 步骤 2: 节点标签（标记支持 RDMA 的节点）
kubectl label node rdma-node-1 feature.node.kubernetes.io/rdma=true

# 步骤 3: 创建 NetworkAttachmentDefinition
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-hostdev-net
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "rdma-hostdev-net",
    "type": "host-device",
    "device": "mlx5_0",
    "ipam": {
      "type": "static",
      "addresses": ["192.168.1.100/24"]
    }
  }'
EOF

# 步骤 4: 在 Pod 中使用
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rdma-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-hostdev-net
spec:
  nodeSelector:
    feature.node.kubernetes.io/rdma: "true"
  containers:
  - name: rdma-app
    image: rdma-hpc:latest
    securityContext:
      capabilities:
        add: ["NET_RAW", "IPC_LOCK"]
    resources:
      limits:
        rdma/hca: "1"
EOF
```

### 3.3 多网卡场景

AI 训练节点通常配备多张 RDMA 网卡（用于 GPU之间的横向通信）：

```bash
# 查看节点的多 RDMA 卡配置
$ ibstat
CA type: MT28908
Number of ports: 1
Firmware version: 20.30.100
Hardware version: 1

# mlx5_0 - 用于存储/管理网络
# mlx5_1 - 用于 GPU间 RDMA 通信

# 在 Kubernetes 中使用多网卡
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: multi-rdma-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [{"name": "storage-net", "interface": "mlx5_0"},
       {"name": "gpu-net", "interface": "mlx5_1"}]
spec:
  containers:
  - name: main
    image: nvidia/cuda:11.8-runtime-ubi8
    command: ["nvidia-smi"]
    resources:
      limits:
        nvidia.com/gpu: 4
        rdma/hca: "2"
EOF
```

---

## 4. macvlan 模式

### 4.1 macvlan 工作原理

macvlan 允许在一个物理网卡上创建多个虚拟接口，每个虚拟接口拥有独立的 MAC 地址和 IP 地址：

```
macvlan 架构：

  Physical NIC (eth0) - MAC: aa:bb:cc:dd:ee:ff
  ┌────────────────────────────────────────────────┐
  │  macvlan 子接口                                │
  │  ┌─────────┐  ┌─────────┐  ┌─────────┐        │
  │  │ macvlan0│  │ macvlan1│  │ macvlan2│  ...   │
  │  │ MAC: A  │  │ MAC: B  │  │ MAC: C  │        │
  │  │ IP: 1.1 │  │ IP: 1.2 │  │ IP: 1.3 │        │
  │  └─────────┘  └─────────┘  └─────────┘        │
  └────────────────────────────────────────────────┘
        ↑            ↑            ↑
     Container A  Container B  Container C
```

### 4.2 RDMA 与 macvlan

macvlan 模式下，容器的虚拟接口仍然映射到物理网卡，因此 RDMA 流量可以正常通过：

```bash
# 1. 在主机上创建 macvlan 接口
# 假设物理网卡为 eth0（连接到 RDMA 网络）
ip link set eth0 up
ip link add rdma-macvlan type macvlan mode private
ip link set rdma-macvlan master eth0
ip addr add 192.168.100.1/24 dev rdma-macvlan
ip link set rdma-macvlan up

# 2. 查看 macvlan 设备
$ ip link show type macvlan
10: rdma-macvlan@eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500
    link/ether aa:bb:cc:dd:ee:ff

# 3. 确认 RDMA 设备可访问
$ ls -la /sys/class/net/eth0/device/infiniband/
mlx5_0

# 4. macvlan 配置
cat <<EOF > /etc/cni/net.d/macvlan-rdma.conf
{
  "cniVersion": "0.3.1",
  "name": "macvlan-rdma",
  "type": "macvlan",
  "master": "eth0",
  "mode": "private",
  "ipam": {
    "type": "host-local",
    "ranges": [[{"subnet": "192.168.100.0/24"}]],
    "routes": [{"gateway": "192.168.100.1"}]
  },
  "capabilities": {
    "rdma": true
  }
}
EOF
```

### 4.3 macvlan 的 RDMA 限制

macvlan 并非完美的 RDMA 解决方案：

```
macvlan RDMA 限制：

  1. PCIe 透传限制
     - macvlan 虚拟接口仍在同一 PCIe 域
     - 所有容器共享同一个物理网卡的 PCIe 带宽
     - 无法获得独立的高带宽

  2. GID 共享
     - 容器不能有独立的 GID
     - 所有容器共享物理网卡的 GID 表
     - 安全隔离较弱

  3. 不支持 SR-IOV 场景
     - 某些 NIC 不支持在 VF 上创建 macvlan
     - 配置复杂度高

  4. 性能开销
     - 数据包经过 macvlan 子接口到物理网卡的额外转发
     - 比 host-device 模式有轻微延迟增加
```

### 4.4 混合模式：macvlan + RDMA

某些场景下需要同时支持 TCP/IP 和 RDMA：

```bash
# 方案：双网络接口
# eth0 - 管理/普通流量（macvlan）
# mlx5_0 - RDMA 专用流量（host-device 或 SR-IOV VF）

# 在 Pod 中使用两个网络
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dual-network-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: |
      [{"name": "management-net", "interface": "eth0"},
       {"name": "rdma-net", "interface": "mlx5_0"}]
spec:
  containers:
  - name: app
    env:
    - name: RDMA_DEVICE
      value: "/dev/infiniband/uverbs0"
```

---

## 5. ipvlan 模式

### 5.1 ipvlan 与 macvlan 的区别

ipvlan 与 macvlan 类似，但有一个关键区别：**ipvlan 共享父接口的 MAC 地址**，而 macvlan 每个子接口有独立的 MAC：

```
macvlan vs ipvlan：

  macvlan:
    父接口 MAC: aa:bb:cc:dd:ee:ff
    子接口1: MAC: 11:22:33:44:55:66 (独立)
    子接口2: MAC: 22:33:44:55:66:77 (独立)
    子接口3: MAC: 33:44:55:66:77:88 (独立)

  ipvlan:
    父接口 MAC: aa:bb:cc:dd:ee:ff
    子接口1: MAC: aa:bb:cc:dd:ee:ff (共享父接口)
    子接口2: MAC: aa:bb:cc:dd:ee:ff (共享父接口)
    子接口3: MAC: aa:bb:cc:dd:ee:ff (共享父接口)
              但 IP 不同
```

### 5.2 ipvlan L2 和 L3 模式

ipvlan 有两种模式：

```
ipvlan 模式：

  L2 模式 (mode: L2):
    - 同一广播域，共享 MAC，不同 IP
    - 相当于在同一个物理网段
    - 适用于桥接/交换场景

  L3 模式 (mode: L3):
    - 每个容器有独立的 IP 命名空间
    - 流量通过路由转发，不在 L2 广播
    - 适用于需要 IP 隔离的高密度场景
    - 减少广播风暴
```

### 5.3 ipvlan RDMA 配置

```bash
# 1. 创建 ipvlan 设备
ip link set eth0 up
ip link add rdma-ipvlan type ipvlan mode L2
ip link set rdma-ipvlan master eth0
ip addr add 192.168.100.10/24 dev rdma-ipvlan
ip link set rdma-ipvlan up

# 2. CNI 配置
cat <<EOF > /etc/cni/net.d/ipvlan-rdma.conf
{
  "cniVersion": "0.3.1",
  "name": "ipvlan-rdma",
  "type": "ipvlan",
  "master": "eth0",
  "mode": "L2",
  "ipam": {
    "type": "static",
    "addresses": ["192.168.100.20/24"]
  }
}
EOF

# 3. 验证 RDMA 设备
# 容器内可以访问 /dev/infiniband/uverbs0
# 但 GID 由物理网卡提供
$ kubectl exec -it pod -- bash
# ibstat
CA type: MT28908
# gidformat
DEV     PORT   INDEX   GID
mlx5_0  1      8       fe80:0000:0000:0000:7cfe:4503:ff00:0e0c
```

### 5.4 ipvlan 的 RDMA 适用场景

```
ipvlan 适合 RDMA 的场景：

  ✅ 多租户环境
     - 共享 MAC 地址减少 ARP 欺骗风险
     - IP 独立便于管理

  ✅ 高密度容器部署
     - L3 模式减少广播
     - 适合 100+ 容器/节点的场景

  ❌ 需要独立 GID 的场景
     - ipvlan 共享 MAC，容器无法拥有独立 GID
     - 部分安全策略无法应用

  ❌ 需要 SR-IOV 独立带宽的场景
     - 所有容器共享同一物理链路
```

---

## 6. RDMA CNI 选型指南

### 6.1 性能对比

```
RDMA CNI 模式性能对比（ConnectX-6 100Gbps，单跳）：

  模式              延迟     带宽利用率   扩展性
  ─────────────────────────────────────────────────
  host-device        3-4 μs   95%+         中等
  SR-IOV VF         3-4 μs   95%+         高
  ipvlan L2         4-5 μs   85-90%       高
  macvlan           4-5 μs   85-90%       高
  IPoIB             8-15 μs  60-70%       低

  建议：
    - AI 训练：host-device 或 SR-IOV
    - 高密度容器：ipvlan L3
    - 传统迁移：macvlan
    - 通用测试：IPoIB
```

### 6.2 场景选型矩阵

```
RDMA CNI 场景选型：

  ┌────────────────────────┬───────────┬────────┬────────┬────────┬─────────┐
  │ 场景                    │ host-dev  │ ipvlan │ macvlan │ IPoIB  │ SR-IOV  │
  ├────────────────────────┼───────────┼────────┼────────┼────────┼─────────┤
  │ AI 训练 (NCCL)          │    ✅     │   ⚠️   │   ⚠️   │   ❌   │    ✅    │
  │ HPC MPI                 │    ✅     │   ⚠️   │   ⚠️   │   ❌   │    ✅    │
  │ 分布式存储 (NVMe-oF)   │    ✅     │   ⚠️   │   ✅   │   ⚠️   │    ✅    │
  │ 多租户 (安全隔离)       │    ⚠️     │   ✅   │   ✅   │   ⚠️   │    ⚠️    │
  │ 高密度容器 (100+/node)  │    ❌     │   ✅   │   ✅   │   ❌   │    ❌    │
  │ 遗留 TCP 应用迁移       │    ⚠️     │   ✅   │   ✅   │   ✅   │    ⚠️    │
  │ 开发/测试              │    ✅     │   ✅   │   ✅   │   ✅   │    ⚠️    │
  └────────────────────────┴───────────┴────────┴────────┴────────┴─────────┘

  ✅ 推荐  ⚠️ 可用  ❌ 不推荐
```

### 6.3 高级配置参数

无论选择哪种 CNI 模式，以下配置参数都值得关注：

```bash
# 1. MTU 配置（RDMA 建议 4096-65520）
# 但容器网络通常使用 1500，需权衡
ethtool --set-priv-flags eth0 mtu 4096

# 2. HCA 超时配置
# 减少链路故障检测时间
echo 2000 > /sys/class/infiniband/mlx5_0/ports/1/ack_timeout

# 3. QP 数量限制
# 避免单容器耗尽系统 QP 资源
cat /sys/class/infiniband/mlx5_0/limits/max_qp

# 4. 设备资源限制
# 在 systemd 或 container runtime 中限制
# cgroup v2
echo +rdma > /sys/fs/cgroup/system.slice/tasks
```

---

## 7. 多网卡与 RDMA 资源调度

### 7.1 RDMA 设备资源模型

Kubernetes 通过 Device Plugin 机制发现和分配 RDMA 设备：

```yaml
# RDMA Device Plugin 配置示例
apiVersion: deviceplugin.k8s.io/v1beta1
kind: DevicePluginOptions
metadata:
  name: rdma
spec:
  # 允许应用请求特定设备
  pressure: false
  # 设备分配策略
  allocationType: "numa"
```

```bash
# 查看节点 RDMA 资源
$ kubectl describe node rdma-node-1 | grep -A5 rdma
Allocatable:
  cpu:                64
  memory:             128Gi
  rdma/rdma-capacity: "4"    # 4 个 RDMA 设备
  nvidia.com/gpu:     8
```

### 7.2 亲和性调度

AI 训练作业通常需要将 RDMA 流量与 GPU 放在一起：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-rdma-pod
spec:
  nodeSelector:
    feature.node.kubernetes.io/rdma: "true"
    feature.node.kubernetes.io/gpu: "true"
  affinity:
    podAffinity:
      # 与其他 GPU Pod 靠近放置
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: gpu-worker
        topologyKey: kubernetes.io/hostname
  containers:
  - name: main
    resources:
      limits:
        nvidia.com/gpu: 2
        rdma/hca: "1"
    env:
    - name: NCCL_IB_HCA
      value: "mlx5_0,mlx5_1"
```

### 7.3 限制与注意事项

```
RDMA CNI 注意事项：

  1. 安全性
     - RDMA 设备访问等同于物理网络访问
     - 容器可绕过 Kubernetes 网络策略直接通信
     - 建议配合 NetworkPolicy 和节点隔离

  2. 资源竞争
     - 多容器共享物理网卡时，带宽竞争不可避免
     - 需要 QoS 策略（DCBX/PFC）

  3. 故障域
     - RDMA 网络故障影响所有使用该网络的容器
     - 需要健康检查和自动恢复机制

  4. 监控挑战
     - RDMA 流量不经过标准网络栈
     - 需要专门工具（Mellanox UFM, NVIDIA DOCA）
```

---

## 8. 实践：使用 Whereabouts 分配 RDMA IP

### 8.1 Whereabouts IPAM

Whereabouts 是一个 CNI IPAM 插件，支持跨节点分配不重复的 IP 地址，适合 RDMA 场景：

```bash
# 安装 Whereabouts
kubectl apply -f https://github.com/dougbtv/whereabouts/releases/download/v0.6/whereabouts.yaml

# 配置使用 Whereabouts 的 macvlan
cat <<EOF > rdma-macvlan-cr.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-macvlan-net
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "rdma-macvlan-net",
    "type": "macvlan",
    "master": "eth0",
    "mode": "bridge",
    "ipam": {
      "type": "whereabouts",
      "range": "192.168.100.0/24",
      "exclude": ["192.168.100.1"],
      "gateway": "192.168.100.1"
    }
  }'
EOF
```

### 8.2 验证 RDMA 连通性

```bash
# 在两个 Pod 中验证 RDMA 通信
# Pod A
kubectl exec -it pod-a -- bash
# ibv_rc_pingpong -d mlx5_0 -g 0 <Pod-B-IP>

# 使用 perftest 测试带宽
kubectl exec -it pod-a -- bash
# perftest -d mlx5_0 -z <Pod-B-GID>
```

---

## 9. 小结

```
本章要点：

  1. RDMA CNI 的核心挑战是设备透传、GID 管理、内存注册和资源隔离

  2. IPoIB 适合传统应用迁移，但性能损失显著，不适合 AI/HPC 场景

  3. host-device 模式性能最佳，但需要预先配置设备，适合专用 RDMA 集群

  4. macvlan 提供良好的隔离性，适合多租户场景，但共享 PCIe 带宽

  5. ipvlan L3 模式支持高密度容器部署，减少广播风暴

  6. SR-IOV 提供了硬件隔离的 VF，是生产环境最佳选择

  7. 实际选型需综合考虑性能、扩展性、安全性和运维复杂度
```