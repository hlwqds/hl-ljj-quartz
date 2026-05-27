---
title: "DPDK 深度探索 ch27a：vDPA、DSA 与 Host/Guest 数据面卸载"
date: 2026-04-09
tags: [dpdk, virtio, vhost, vdpa, dsa, dmadev, vfio, iommu, virtualization]
description: "深入理解 DPDK 中 vDPA、DSA、dmadev 如何优化 Host 与 Guest 之间的数据拷贝和 virtqueue 数据路径"
---

# DPDK 深度探索 ch27a：vDPA、DSA 与 Host/Guest 数据面卸载

> [!abstract] 核心要点
> 普通 NIC RX/TX 的 DMA 已经由 ethdev PMD 和 NIC descriptor ring 完成；DSA/dmadev
> 解决的是软件 vhost 路径里的 Host/Guest 内存拷贝；vDPA 则更进一步，让硬件直接理解
> virtqueue，把 vhost 数据面从 Host CPU 上卸掉。
>
> 前置阅读：[[2026-04-09-dpdk-deep-dive-ch16-vhost-user|第十六章：vhost-user 与 virtio 加速]]、
> [[2026-04-09-dpdk-deep-dive-ch19-vdpa|第十九章：vDPA 数据面加速与驱动]]、
> [[2026-04-09-dpdk-deep-dive-ch27-memory-dma|第二十七章：内存优化——DMA 引擎与零拷贝]]。

## 1. 先把问题说清楚

前面讨论 DMA 时，最容易混淆的是这三类“DMA”：

```text
普通 NIC RX/TX DMA:
  NIC 根据 RX/TX descriptor 读写 mbuf
  rte_eth_rx_burst() / rte_eth_tx_burst() 不需要应用手动调用 dmadev

DMA copy engine:
  专门做 memory-to-memory copy
  DPDK 用 dmadev 抽象这类硬件

vDPA:
  硬件直接理解 virtqueue
  让 virtio/vhost 数据面尽量绕过 Host 软件 vhost copy
```

普通物理网卡转发是：

```text
NIC RX DMA -> mbuf -> rte_eth_rx_burst()
  -> 应用改 header / metadata
  -> rte_eth_tx_burst()
  -> NIC TX DMA
```

这里没有必要自己再做：

```text
RX mbuf -> DMA copy -> TX mbuf
```

真正需要 DSA/dmadev/vDPA 的地方，是虚拟化路径：

```text
Guest VM
  virtio driver
  virtqueue buffer

Host
  vhost backend
  OVS-DPDK / VPP / DPDK app
  mbuf
```

问题变成：

```text
Guest memory 里的 packet
  怎么高效进入 Host mbuf？

Host mbuf 里的 packet
  怎么高效进入 Guest virtqueue buffer？
```

## 2. 软件 vhost-user 为什么会有 copy

vhost-user 的基本分层是：

```text
Guest:
  application
    -> socket
    -> virtio-net driver
    -> virtqueue descriptor

Host:
  QEMU 负责 virtio 设备模型和控制面
  vhost-user backend 负责数据面
  OVS-DPDK / VPP / DPDK app 处理 packet
```

Guest 的 virtqueue descriptor 里放的是 Guest 视角的地址：

```text
virtqueue descriptor:
  addr = GPA
  len  = buffer length
```

vhost 后端收到 vhost-user memory table 后，可以把 GPA 转成 Host 可访问地址：

```text
GPA -> HVA
```

如果 Host 侧数据面使用 mbuf，而 Guest 侧使用 virtqueue buffer，很多软件 vhost 路径会
发生 copy：

```text
Guest TX:
  Guest virtqueue buffer
    -> vhost backend copy
    -> Host mbuf
    -> OVS-DPDK / VPP / NIC

Guest RX:
  Host mbuf
    -> vhost backend copy
    -> Guest virtqueue buffer
    -> Guest virtio driver
```

这个 copy 不是普通 NIC RX/TX 的 DMA。它是 Host CPU 在两个内存域之间搬 packet：

```text
Host mbuf memory <-> Guest shared memory
```

包越大、VM 越多、队列越多，这部分 CPU 开销越明显。

## 3. DSA/dmadev：把 copy 从 CPU 挪到 DMA copy engine

Intel DSA（Data Streaming Accelerator）这类硬件的目标是：

```text
CPU:
  提交 copy 描述符
  处理其他包
  回头 poll completion

DSA:
  做真正的 memory-to-memory copy
```

DPDK 不希望应用直接绑定某一种硬件，所以提供了 dmadev：

```text
dmadev:
  DPDK 对 DMA copy engine 的统一抽象

idxd PMD:
  DPDK 里用于 Intel DSA/IDXD 的 dmadev driver

常见 API:
  rte_dma_copy()
  rte_dma_submit()
  rte_dma_completed()
```

一个简化 copy 模型是：

```text
source IOVA
destination IOVA
length
  -> rte_dma_copy()
  -> rte_dma_submit()
  -> hardware copy
  -> rte_dma_completed()
```

放回 vhost 场景就是：

```text
Guest RX:
  Host mbuf IOVA
    -> dmadev copy
    -> Guest buffer IOVA
    -> vhost 更新 used ring
    -> Guest 收到包

Guest TX:
  Guest buffer IOVA
    -> dmadev copy
    -> Host mbuf IOVA
    -> Host 数据面继续处理
```

注意：DSA/dmadev 没有让 copy 消失。它只是把 copy 从 CPU 搬到专门的硬件：

```text
CPU memcpy:
  CPU 读源
  CPU 写目标
  CPU cache 被污染

dmadev copy:
  CPU 提交 descriptor
  DSA 读源、写目标
  CPU 可以处理其他包
```

所以它适合：

```text
大包 copy
批量 copy
vhost async copy
Host/Guest memory 搬运
CPU 已经被 packet processing 占满
```

不适合：

```text
很小的 copy
单个 copy 同步等待完成
普通 NIC RX/TX 转发
能复用 mbuf 的路径
```

## 4. vhost async path：谁来组织 dmadev

真实工程里，通常不是业务应用自己手写：

```text
GPA -> HVA -> IOVA
dmadev queue
in-flight packet
completion
used ring update
```

DPDK vhost library 提供了异步数据路径。它的职责是：

```text
vhost library:
  管 virtqueue
  管 guest memory table
  管 in-flight packet
  暴露 async enqueue/dequeue API

应用 / OVS-DPDK / VPP:
  选择使用哪些 DMA device / vchannel
  注册 vhost async channel
  调用 async enqueue/dequeue
  poll completed packets

dmadev / DSA:
  执行 memory-to-memory copy
```

从 DPDK vhost 文档的角度看，异步路径的重点是：

```text
启用 async data path
为 vhost queue 注册 async channel
提交 enqueue/dequeue 请求
poll completion
在完成之前不能释放相关 mbuf
```

因此更准确的说法是：

```text
应用不需要自己解析每个 GPA 并手搓 DMA copy；
但应用需要配置 vhost async path 使用哪个 dmadev/vchannel，
并按 async API 的生命周期处理 in-flight packets。
```

这也是为什么它不是普通 `rte_eth_tx_burst()` 的替代品，而是 vhost-user software
backend 的加速路径。

## 5. vDPA：让硬件直接理解 virtqueue

DSA/dmadev 解决的是：

```text
软件 vhost 仍然存在
virtqueue 仍然由 Host 软件解析
只是 copy 交给 DMA engine
```

vDPA 更进一步：

```text
硬件直接理解 virtqueue
硬件直接访问 Guest memory
硬件完成数据面收发
Host 软件主要负责控制面配置
```

简化模型：

```text
Guest virtio-net driver
  -> virtqueue
  -> vDPA device / SmartNIC / DPU
  -> hardware datapath
  -> NIC / switch / representor / backend network
```

DPDK vhost library 里，vDPA 是一种 accelerated backend：

```text
vhost-user socket:
  仍然用于 QEMU 和 backend 之间交换控制信息

vDPA device:
  接管 datapath
  读取 virtqueue
  DMA guest memory
  更新 used ring / interrupt

DPDK vdpa app / PMD:
  创建 vhost-user socket
  attach vDPA device
  配置 feature、queue、notify area 等
```

所以 vDPA 的目标不是“更快地 copy”，而是尽量避免 Host 软件 vhost 数据面：

```text
Software vhost + dmadev:
  Host 软件解析 virtqueue
  dmadev 帮忙 copy

vDPA:
  硬件解析 virtqueue
  硬件 DMA guest memory
  Host 软件数据面大幅减少
```

## 6. 三条路径对比

| 路径 | 数据面主角 | 是否需要 Host 软件解析 virtqueue | 是否需要 Host/Guest copy | 典型硬件 |
| --- | --- | --- | --- | --- |
| 软件 vhost-user | Host CPU | 需要 | 常见需要 | CPU |
| vhost async + dmadev | Host CPU + DMA copy engine | 需要 | 需要，但 copy offload | Intel DSA、I/OAT、其他 dmadev |
| vDPA | vDPA 设备 / SmartNIC / DPU | 尽量由硬件处理 | 尽量避免 Host 软件 copy | IFCVF、mlx5 vDPA、NFP、Xilinx 等 |

从“卸载程度”看：

```text
软件 vhost-user:
  CPU 做 virtqueue + copy + packet path

vhost async + DSA:
  CPU 做 virtqueue + packet path
  DSA 做 copy

vDPA:
  硬件做 virtqueue datapath
  CPU 做控制面和异常路径
```

## 7. 和 SR-IOV、virtio、vhost-user 的关系

这些方案容易混在一起：

```text
virtio:
  Guest 看到的半虚拟化设备模型
  核心是 virtqueue

vhost-user:
  把 virtio 数据面交给 Host 用户态 backend
  例如 OVS-DPDK、VPP、SPDK

dmadev / DSA:
  帮 software vhost backend 加速内存 copy
  不改变 Guest 看到的 virtio 设备语义

vDPA:
  用硬件作为 virtio/vhost 数据面的 backend
  Guest 仍然使用 virtio driver

SR-IOV VF passthrough:
  Guest 直接拿到 VF PCI function
  Guest 需要对应 VF 驱动
  不再是 virtio 设备语义
```

一句话：

```text
vDPA 保留 virtio 语义，但把数据面硬件化；
SR-IOV 直接把设备功能给 Guest，但平台可迁移性和统一 virtio 语义会变弱。
```

## 8. 什么时候选什么

### 8.1 普通云主机网络

如果目标是通用 VM 网络：

```text
Guest 使用 virtio-net
Host 使用 vhost-user / OVS-DPDK
需要兼容、迁移、运维一致性
```

可以先从软件 vhost-user 做起，再看瓶颈：

```text
瓶颈在 copy:
  考虑 vhost async + dmadev / DSA

瓶颈在 Host 软件 virtqueue 处理:
  考虑 vDPA
```

### 8.2 NFV/CNF 高性能场景

如果是虚拟化网元：

```text
UPF / firewall / LB / router
大包吞吐或高 PPS
Host CPU 已经紧张
```

选择顺序通常是：

```text
想保留 virtio 生态:
  vhost-user -> vhost async + DSA -> vDPA

可以接受设备直通:
  SR-IOV VF passthrough
```

### 8.3 不要过早引入硬件卸载

硬件卸载不是免费午餐：

```text
DSA/dmadev:
  要配置 DMA devices / work queues
  要处理 async completion
  要考虑 NUMA、batch、queue depth

vDPA:
  要匹配硬件能力和 virtio feature
  要处理 live migration、control path、统计和排障
  要确认平台/驱动支持
```

如果普通软件路径已经满足 SLA，引入硬件卸载可能只是增加复杂度。

## 9. 排障时看什么

### 9.1 vhost async + dmadev

重点看：

```text
DMA device 是否被 DPDK 识别
dmadev queue / vchannel 是否配置
vhost queue 是否注册 async channel
in-flight packets 是否堆积
completion 是否及时 poll
DMA device 和 VM memory 是否在同 NUMA socket
```

常见问题：

```text
只 enqueue 不 poll completion:
  mbuf 不会释放，in-flight 堆积

copy 太小:
  DMA submit/completion 开销超过收益

NUMA 放错:
  DSA 访问远端 memory，收益下降
```

### 9.2 vDPA

重点看：

```text
vDPA device 是否被 DPDK 探测
vhost-user socket 是否创建
QEMU 是否使用对应 socket
virtio feature 是否协商成功
queue 数量和 interrupt/notify 配置是否匹配
live migration 能力是否满足要求
```

vDPA 排障更像“设备 + virtio + vhost-user”三方联合排障，而不是单纯看 DPDK worker
线程。

## 10. 总结

这几个概念可以这样收束：

```text
普通 NIC RX/TX:
  ethdev PMD 管 descriptor
  NIC 自己 DMA mbuf
  应用不需要 dmadev

软件 vhost-user:
  Host CPU 处理 virtqueue
  Host/Guest memory 之间可能有 copy

DSA/dmadev:
  把 vhost copy 交给 DMA copy engine
  减少 CPU copy 开销

vDPA:
  让硬件直接服务 virtqueue
  尽量把 vhost 数据面从 Host CPU 上卸载
```

所以：

```text
dmadev 是 copy offload；
vDPA 是 virtqueue datapath offload；
SR-IOV 是设备功能直通；
它们解决的问题相邻，但不是同一个层次。
```

---

> [!tip] 参考文献
>
> - DPDK, "Vhost Library", https://doc.dpdk.org/guides/prog_guide/vhost_lib.html
> - DPDK, "vDPA Device Drivers", https://doc.dpdk.org/guides/vdpadevs/index.html
> - DPDK, "Vdpa Sample Application", https://doc.dpdk.org/guides/sample_app_ug/vdpa.html
> - DPDK, "IDXD DMA Device Driver", https://doc.dpdk.org/guides/dmadevs/idxd.html
> - DPDK, "DMA Device Library", https://doc.dpdk.org/guides/prog_guide/dmadev.html
