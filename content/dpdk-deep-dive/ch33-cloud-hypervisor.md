---
title: "DPDK 深度探索 ch16b：Cloud Hypervisor 与 DPDK 虚拟化路径"
date: 2026-04-10 12:00:00
tags: [dpdk, cloud-hypervisor, kvm, virtio, vhost-user, vfio, sriov, vdpa, vm]
description: "从 DPDK 视角理解 Cloud Hypervisor：virtio-net、vhost-user、OVS-DPDK、VFIO/SR-IOV、vDPA 与 IOMMU 的关系"
---

# DPDK 深度探索 ch16b：Cloud Hypervisor 与 DPDK 虚拟化路径

> [!abstract] 核心要点
> Cloud Hypervisor 是面向云工作负载的轻量 VMM。它不是 DPDK 组件，也不是 OVS
> 替代品；它负责创建 VM、virtio 设备、vhost-user 连接、VFIO 设备直通和 vDPA
> 设备接入。DPDK 常出现在 Host 的 vhost-user backend、OVS-DPDK/VPP 数据面，或者
> Guest 内部的 DPDK 应用里。

> 前置阅读：[[ch16-vhost-user|第十六章：vhost-user 与 virtio 加速]]、
> [[ch16a-ovs-dpdk-vhost-user-lab|第十六章补充：OVS-DPDK 与 vhost-user 最小实战]]、
> [[ch35-sr-iov|第三十五章：SR-IOV 与 VF 管理机制]]。

## 1. 先纠正原文的几个问题

原文把 Cloud Hypervisor 写成了“云环境 Hypervisor 泛论”，混在一起讲 KVM、Xen、
ESXi、AWS Nitro、Azure、GCP。这种写法容易让读者误解几个关键点：

```text
Cloud Hypervisor:
  一个具体的 VMM 项目
  类似 QEMU 的角色，但更面向云场景和现代 virtio/VFIO/vhost-user

KVM:
  Linux 内核里的虚拟化加速模块
  提供 vCPU 运行、VM exit、内存虚拟化、中断注入等能力

QEMU / Cloud Hypervisor / Firecracker:
  用户态 VMM
  调 KVM API 创建和管理 VM
  提供设备模型、virtio、vhost-user、VFIO 等接口

Xen / ESXi / Hyper-V:
  另外的 hypervisor 栈
  不是 Cloud Hypervisor 的同类实现细节
```

本文只聚焦一个问题：

> Cloud Hypervisor 场景里，DPDK 网络路径到底怎么接进去？

## 2. Cloud Hypervisor 在栈里的位置

Cloud Hypervisor 运行在 Host 用户态，通过 KVM 或其他底层虚拟化后端创建 VM。

```text
Guest VM
  ├── Linux kernel virtio-net driver
  ├── or DPDK virtio PMD
  ├── or vendor VF driver
  └── or Guest DPDK PMD

Cloud Hypervisor
  ├── VM lifecycle
  ├── virtio device model
  ├── vhost-user socket connection
  ├── VFIO device passthrough
  └── vDPA attachment

Host datapath
  ├── Linux tap / bridge
  ├── OVS kernel
  ├── OVS-DPDK / VPP / DPDK vhost backend
  ├── SR-IOV VF
  └── SmartNIC / DPU / vDPA device

Hardware
  └── NIC / IOMMU / CPU / memory
```

把角色说清楚后，DPDK 可能出现在三个地方：

```text
Host DPDK:
  OVS-DPDK、VPP、SPDK、vhost-user backend

Guest DPDK:
  VM 内应用直接使用 DPDK virtio PMD 或 VF PMD

NIC/DPU offload:
  vDPA、SR-IOV representor、rte_flow/TC offload
```

Cloud Hypervisor 本身不负责执行 DPDK 转发逻辑。它负责把 VM 的设备和 Host 的后端接起来。

## 3. 四条常见网络路径

### 3.1 路径 A：virtio-net + tap

这是最普通的路径：

```text
Guest app
  -> Guest kernel TCP/IP
  -> virtio-net driver
  -> Cloud Hypervisor virtio-net device
  -> Host tap
  -> Linux bridge / OVS kernel / nftables / routing
  -> physical NIC
```

特点：

```text
优点:
  简单、兼容性好、适合普通 VM

缺点:
  Host kernel 网络栈参与多
  不是 DPDK 快路径
  小包性能和延迟通常不如 vhost-user/SR-IOV/vDPA
```

示意命令：

```bash
cloud-hypervisor \
  --kernel ./vmlinux \
  --cmdline "console=hvc0 root=/dev/vda1" \
  --disk path=./guest.img \
  --cpus boot=4 \
  --memory size=4096M \
  --net tap=ch-tap0,mac=02:00:00:00:00:01
```

这条路径和 DPDK 关系不大，除非 Guest 内应用使用 DPDK virtio PMD 直接驱动这个
virtio-net 设备。

### 3.2 路径 B：vhost-user + OVS-DPDK

这是和 DPDK 最相关的 Cloud Hypervisor 网络路径：

```text
Guest virtio-net frontend
  -> virtqueue in Guest memory
  -> Cloud Hypervisor vhost-user client
  -> Unix socket
  -> OVS-DPDK / VPP / DPDK vhost-user backend
  -> DPDK ethdev / vSwitch datapath
  -> physical NIC or another VM
```

这里要分清：

```text
Cloud Hypervisor:
  给 Guest 暴露 virtio-net 设备
  通过 vhost-user socket 把 virtqueue、memory table、eventfd 交给 backend

OVS-DPDK:
  作为 vhost-user backend
  mmap Guest memory
  处理 virtqueue
  把包接入 userspace datapath

Guest:
  看到的仍然是 virtio-net
```

和 QEMU/OVS-DPDK 的关系类似，只是 VMM 从 QEMU 换成 Cloud Hypervisor。

Host 侧 OVS-DPDK 端口可以类似这样配置：

```bash
sudo ovs-vsctl --may-exist add-br br-vhu -- set bridge br-vhu datapath_type=netdev

sudo ovs-vsctl --may-exist add-port br-vhu vhu-ch0 \
  -- set Interface vhu-ch0 type=dpdkvhostuserclient \
  options:vhost-server-path=/var/run/openvswitch/vhu-ch0.sock
```

Cloud Hypervisor 侧使用 vhost-user net socket。实际参数名称以当前版本文档为准，结构上是：

```text
--memory size=4096M,shared=on
--net vhost_user=true,socket=/var/run/openvswitch/vhu-ch0.sock,vhost_mode=server,...
```

关键要求：

```text
Guest memory 必须能被 backend 共享/mmap
socket server/client 角色要匹配
OVS-DPDK bridge 要使用 datapath_type=netdev
vhost-user port 状态要 up
Host hugepage/NUMA/PMD 线程要规划好
```

这条路径适合：

```text
云主机网络
OVS-DPDK / VPP vSwitch
需要安全组、ACL、overlay、镜像、流表统计
仍希望 Guest 使用通用 virtio-net
```

### 3.3 路径 C：VFIO + SR-IOV VF passthrough

这条路径绕过 Host vSwitch：

```text
Guest
  -> vendor VF driver or Guest DPDK PMD
  -> SR-IOV VF PCI function
  -> NIC hardware / embedded switch
  -> wire
```

Host 准备 VF：

```bash
PF=0000:3d:00.0
echo 4 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs
readlink -f /sys/bus/pci/devices/$PF/virtfn*

sudo modprobe vfio-pci
sudo dpdk-devbind.py -b vfio-pci 0000:3d:00.1
```

Cloud Hypervisor 通过 VFIO 把这个 VF 加给 VM：

```bash
cloud-hypervisor \
  --kernel ./vmlinux \
  --cmdline "console=hvc0 root=/dev/vda1" \
  --disk path=./guest.img \
  --cpus boot=4 \
  --memory size=4096M \
  --device path=/sys/bus/pci/devices/0000:3d:00.1
```

Guest 内有两种用法：

```text
普通 Guest:
  加载厂商 VF kernel driver
  例如 iavf、ixgbevf、mlx5_core、bnxt_en、ena
  应用走 socket

Guest DPDK:
  Guest 内再把这个 VF 绑定 vfio-pci
  DPDK app 使用对应 PMD
  例如 iavf PMD、ixgbe PMD、mlx5 PMD、bnxt PMD
```

注意 mlx5 的例外：

```text
Intel/部分厂商 VF:
  常见做法是绑定 vfio-pci 后给 DPDK PMD 使用

NVIDIA/Mellanox mlx5:
  DPDK mlx5 PMD 通常依赖 mlx5_core、mlx5_ib、rdma-core、libibverbs/libmlx5
  设备常保持绑定 mlx5_core
  不要机械地把 mlx5 VF 绑定到 vfio-pci
```

VFIO/SR-IOV 适合：

```text
低延迟、高吞吐
NFV/CNF/DPDK workload
路径简单、流量不需要 Host vSwitch 每包处理
```

代价：

```text
Host vSwitch 可观测性下降
安全组/ACL/镜像/overlay 能力依赖硬件 offload 或 representor
热迁移困难
VF 数、队列数、MSI-X、IOMMU group 都是硬约束
```

### 3.4 路径 D：vDPA

vDPA 的目标是：Guest 仍然看到 virtio-net，但数据面尽量由硬件处理。

```text
Guest virtio-net
  -> virtqueue
  -> vDPA device
  -> NIC / SmartNIC / DPU hardware datapath
```

它和 SR-IOV VF 的区别：

```text
SR-IOV VF:
  Guest 看到厂商 VF PCI 设备
  Guest 需要厂商 VF driver 或 DPDK VF PMD

vDPA:
  Guest 看到 virtio-net
  Guest 可以继续用 virtio_net driver
  Host/硬件处理 virtqueue datapath
```

Cloud Hypervisor 支持把 vhost-vDPA 设备接进 VM。Host 上通常会看到：

```bash
vdpa dev show
ls -l /dev/vhost-vdpa-*
```

Cloud Hypervisor 参数形态类似：

```text
--net vdpa=/dev/vhost-vdpa-0,...
```

实际能否跑通取决于：

```text
NIC/DPU 是否支持 vDPA
kernel 是否有 vhost_vdpa 和厂商 vdpa driver
firmware/rdma-core/OFED/DPDK/Cloud Hypervisor 版本是否匹配
IOMMU 和 DMA mapping 是否正确
```

vDPA 的价值在于：

```text
保留 virtio 兼容性
减少 Host 软件 vhost datapath
比传统 SR-IOV 更接近云平台的通用 virtio 模型
```

## 4. Guest memory、hugepage 和 vhost-user

vhost-user 的关键不是 socket 本身，而是 Host backend 要能访问 Guest memory。

控制面大概是：

```text
Cloud Hypervisor
  -> 创建 Guest memory
  -> 创建 virtio-net device
  -> 通过 vhost-user socket 发送:
       memory table
       vring 地址
       kickfd/callfd
       feature negotiation

OVS-DPDK / DPDK vhost backend
  -> mmap Guest memory
  -> GPA -> HVA 转换
  -> 读写 virtqueue descriptor
```

所以配置上要关注：

```text
Guest memory 是否 shared
是否使用 hugepage
vhost-user backend 是否有权限 mmap
socket 路径权限是否正确
NUMA node 是否和 PMD/NIC 接近
```

QEMU 示例里常见 `memory-backend-file,share=on`。Cloud Hypervisor 的命令行里则常见
`--memory size=...,shared=on`，或者在 memory zone 里配置 `shared=on`、`hugepages=on`、
`host_numa_node=...`。不要只复制 QEMU 参数，要按 Cloud Hypervisor 当前版本文档配置。

## 5. IOMMU 分两层看

这里最容易混：

```text
Host IOMMU:
  保护 Host 物理内存
  VFIO、vDPA、DPDK DMA mapping 依赖它
  关注 IOMMU group、/dev/vfio、DMA isolation

Guest vIOMMU:
  VM 内看到的虚拟 IOMMU
  Guest 里做设备直通、VFIO、嵌套场景时可能需要
```

SR-IOV VF 直通给 Cloud Hypervisor VM 时，Host 侧至少要关注：

```bash
readlink -f /sys/bus/pci/devices/0000:3d:00.1/iommu_group
ls -l /dev/vfio/
dmesg | grep -i -E "iommu|vfio"
```

Guest 里是否需要 vIOMMU，要看你的 Guest workload：

```text
普通 VF kernel driver:
  通常不需要 Guest 自己使用 VFIO

Guest DPDK + vfio-pci:
  Guest 内可能需要 IOMMU/VFIO 支持
  也可能使用 no-IOMMU/unsafe 模式，但生产不建议
```

## 6. 和 QEMU 的差异应该怎么理解

从 DPDK 网络角度看，QEMU 和 Cloud Hypervisor 的区别没有“virtio/vhost-user/VFIO
本质变了”那么大。真正变化的是 VMM 实现、命令行、设备模型覆盖面和云场景取舍。

相同点：

```text
都可以基于 KVM 创建 VM
都可以给 Guest 暴露 virtio-net
都可以接 vhost-user backend
都可以做 VFIO device passthrough
都可以配合 hugepage/shared memory
```

不同点：

```text
QEMU:
  功能覆盖极广
  设备模拟多
  生态成熟
  命令参数复杂

Cloud Hypervisor:
  面向云 workload 和现代 virtio/VFIO/vhost-user
  设备模型更收敛
  Rust 实现
  更强调轻量、可维护和云原生集成
```

所以迁移思路是：

```text
QEMU vhost-user command line
  -> 找到对应 Cloud Hypervisor --net vhost_user/socket/shared memory 参数

QEMU -device vfio-pci,host=...
  -> Cloud Hypervisor --device path=/sys/bus/pci/devices/...

QEMU virtio-net-pci
  -> Cloud Hypervisor --net ...
```

## 7. Cloud Hypervisor + OVS-DPDK 观察点

启动后不要只看 VM 能不能 ping。按这几层看：

### 7.1 Cloud Hypervisor 进程

```bash
ps -ef | grep cloud-hypervisor
```

重点看：

```text
--net 是否是 tap、vhost-user 还是 vDPA
--memory 是否满足 vhost-user shared memory 要求
--device 是否指向正确 PCI sysfs device
```

### 7.2 OVS-DPDK

```bash
ovs-vsctl show
ovs-vsctl list Interface
ovs-appctl dpif/show
ovs-appctl dpif-netdev/pmd-rxq-show
```

重点看：

```text
datapath_type=netdev
Interface type=dpdkvhostuserclient 或 dpdkvhostuser
vhost socket path 是否匹配
link_state 是否 up
statistics 是否增长
PMD 是否 poll 到 vhost port
```

### 7.3 Guest

普通 virtio-net：

```bash
lspci | grep -i virtio
ethtool -i eth0
ip -s link show eth0
```

SR-IOV VF：

```bash
lspci -nnk
ethtool -i eth0
dmesg | grep -i -E "iavf|ixgbevf|mlx5|bnxt|ena|vf"
```

Guest DPDK：

```bash
dpdk-devbind.py --status
dpdk-testpmd -l 0-3 -n 4 -- -i
```

### 7.4 Host PCI/VFIO

```bash
lspci -nnk -s 0000:3d:00.1
readlink -f /sys/bus/pci/devices/0000:3d:00.1/iommu_group
ls -l /dev/vfio/
```

重点看：

```text
VF 是否绑定给 vfio-pci
IOMMU group 是否干净
Cloud Hypervisor 进程是否有权限打开 /dev/vfio/<group>
```

## 8. 常见问题

### 8.1 vhost-user socket 连不上

检查：

```bash
ls -l /var/run/openvswitch/
ss -xl | grep vhu
ovs-vsctl list Interface vhu-ch0
```

常见原因：

```text
socket 路径不一致
server/client 角色不匹配
OVS-DPDK 没有启用 DPDK EAL
Cloud Hypervisor 没有按 vhost-user 模式启动
socket 权限不允许 VMM 访问
```

### 8.2 Guest 里有 virtio 设备但没有网卡

检查：

```bash
lspci -nn
dmesg | grep -i virtio
modprobe virtio_net
```

可能原因：

```text
Guest 内核没有 virtio_net
virtio feature 协商失败
设备模型参数错误
```

### 8.3 VFIO device passthrough 失败

检查：

```bash
dmesg | grep -i vfio
readlink -f /sys/bus/pci/devices/0000:3d:00.1/iommu_group
ls -l /dev/vfio/
```

常见原因：

```text
Host IOMMU 没开
设备没有绑定 vfio-pci
IOMMU group 里还有其他未处理设备
Cloud Hypervisor 没有权限打开 /dev/vfio/<group>
PF/VF 正被其他进程占用
```

### 8.4 Guest DPDK 找不到 mlx5 VF

mlx5 要单独看。它通常依赖内核和 RDMA userspace 栈：

```bash
lsmod | grep mlx5
ibv_devices
ibv_devinfo
rdma link show
```

如果是 mlx5 PMD，不要机械套用“所有 DPDK 设备都绑定 vfio-pci”的经验。

### 8.5 性能不如预期

按这个顺序查：

```text
1. VM vCPU pinning
2. Host PMD/worker CPU 是否独占
3. Guest memory / hugepage / NUMA 是否靠近 NIC
4. vhost-user socket 对应的 OVS PMD 是否在同 NUMA
5. VF 队列数、RSS、MSI-X 是否足够
6. IOMMU 模式和 DMA mapping 是否造成额外开销
7. 是否和 irqbalance、宿主机普通中断、其他 VM 抢 CPU
8. Pktgen 或流量源本身是否已经是瓶颈
```

## 9. 选型建议

| 目标                                  | Cloud Hypervisor 网络路径                  |
| ------------------------------------- | ------------------------------------------ |
| 普通 VM，兼容优先                     | virtio-net + tap                           |
| 云网络管控，OVS-DPDK/VPP 数据面       | virtio-net + vhost-user                    |
| 极致性能，Guest 可接受厂商 VF 驱动    | VFIO + SR-IOV VF                           |
| Guest 保持 virtio，硬件卸载 virtqueue | vDPA                                       |
| Guest 内跑 DPDK NF                    | virtio PMD 或 VF PMD，取决于性能和管控需求 |

可以这样记：

```text
tap:
  最简单

vhost-user:
  Host DPDK vSwitch 最经典

SR-IOV VFIO:
  性能最直接，但管控变硬件化

vDPA:
  virtio 兼容性 + 硬件 datapath offload
```

## 10. 总结

Cloud Hypervisor 和 DPDK 的关系不是“谁包含谁”，而是分层协作：

```text
Cloud Hypervisor:
  负责 VM、virtio、vhost-user、VFIO、vDPA 接入

DPDK:
  负责 Host vSwitch/backend 数据面
  或 Guest 内 packet processing

VFIO/IOMMU:
  负责 PCI 设备安全分配和 DMA 隔离

NIC/DPU:
  越来越多承担 virtqueue、switching、flow、crypto、tunnel offload
```

如果你在排障，永远先问清楚当前是哪条路径：

```text
tap?
vhost-user?
VFIO/SR-IOV?
vDPA?
Guest DPDK?
Host OVS-DPDK?
```

路径问清楚后，再去看对应的 socket、VFIO group、virtio driver、PMD、NUMA 和硬件 offload。

---

## 参考资源

- [Cloud Hypervisor GitHub](https://github.com/cloud-hypervisor/cloud-hypervisor)
- [Cloud Hypervisor Command Line Reference](https://www.cloudhypervisor.org/docs/prologue/commands/)
- [Cloud Hypervisor Documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/tree/main/docs)
- [Cloud Hypervisor VFIO Documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vfio.md)
- [Cloud Hypervisor vhost-user-net Testing](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vhost-user-net-testing.md)
- [Cloud Hypervisor vDPA Documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vdpa.md)
- [QEMU vhost-user Protocol](https://www.qemu.org/docs/master/interop/vhost-user.html)
