---
title: "DPDK 深度探索 ch35b：虚拟化的下一站——DPU、机密计算与异构 I/O"
date: 2026-04-10 13:00:00
tags:
  [
    dpdk,
    virtualization,
    dpu,
    ipu,
    smartnic,
    confidential-computing,
    sev-snp,
    tdx,
    arm-cca,
    spdk,
    virtio,
    gpudev,
  ]
description: "从数据面、基础设施面和可信边界三个维度，分析 DPU/IPU、SmartNIC、机密虚拟机、virtio、SPDK 与 GPU Direct 如何改变 DPDK 的部署位置和工程边界"
---

# DPDK 深度探索 ch35b：虚拟化的下一站——DPU、机密计算与异构 I/O

> [!info] 章节定位
> 本文原文件名使用 `ch35`，但系列中第三十五章已经是
> [[2026-04-09-dpdk-deep-dive-ch35-sr-iov|SR-IOV 与 VF 管理]]。
> 因此本文按 **ch35b 专题章**处理，避免与 SR-IOV 机制章混淆。
>
> 资料核对日期：**2026-06-09**。产品路线图、软件版本和商用状态会继续变化，
> 部署前应再次核对厂商文档。

> [!info] 关联章节
>
> - [[2026-04-09-dpdk-deep-dive-ch19b-dpu-smartnic|DPU / SmartNIC 编程与 API]]
> - [[2026-04-09-dpdk-deep-dive-ch27a-vdpa-dsa-host-guest-accel|vDPA / DSA / Host-Guest 卸载]]
> - [[2026-04-09-dpdk-deep-dive-ch34-live-migration|热迁移]]
> - [[2026-04-09-dpdk-deep-dive-ch36-p4-dpdk|P4 可编程数据面]]
> - [[2026-04-09-dpdk-deep-dive-ch38-dpdk-ebpf|DPDK 与 eBPF / XDP]]

> [!abstract] 核心结论
> 下一代虚拟化不是简单地“把 DPDK 搬到 DPU”，而是同时发生三种变化：
>
> 1. **基础设施面与租户计算分离**：网络、存储、安全和遥测逐步离开 host CPU。
> 2. **数据路径分层**：控制核、通用数据面核、可编程流水线和固定功能加速器各司其职。
> 3. **可信边界收缩**：机密 VM 不再默认信任 hypervisor，所有共享内存和 DMA 都必须重新审视。
>
> DPDK 不会因为 DPU、eBPF 或硬件卸载而消失。它的角色会从“主机上的唯一高速路径”
> 变成“跨 host、DPU、虚拟设备和加速器的用户态数据面组件”。

---

## 1. 先澄清：DPU、IPU 和 SmartNIC 不是严格标准

这些名称首先是产品和市场分类，不是像 PCIe、virtio 那样有统一边界的协议标准。
不同厂商对同一名称的使用并不完全一致。

| 名称     | 常见含义                                             | 不能据此推断                  |
| -------- | ---------------------------------------------------- | ----------------------------- |
| NIC      | 提供网络连接并执行固定功能卸载                       | 一定不能编程                  |
| SmartNIC | 带可编程数据路径、FPGA、流处理器或嵌入式 CPU 的 NIC  | 一定能运行完整 Linux          |
| DPU      | 将网络、存储、安全和虚拟化服务放到独立基础设施处理器 | 所有功能都在 Arm/x86 核上执行 |
| IPU      | Intel 对基础设施处理器的命名，强调隔离和基础设施服务 | CPU 架构一定是 x86            |
| SuperNIC | 面向 AI/HPC 网络的数据移动与网络加速产品类别         | 等同于完整 DPU                |

> [!warning] 常见误区
> **DPU 不等于“带 Arm 核的网卡”**。真正重要的是：
>
> - 它是否拥有独立的启动链、管理面和故障域；
> - host 是否能绕过基础设施策略；
> - 数据面主要跑在通用核、可编程流水线还是固定功能引擎；
> - 网络、存储和安全状态由谁编排、升级和恢复。

### 1.1 从功能卸载到基础设施隔离

```text
传统 NIC
  checksum / TSO / RSS / VLAN 等固定功能
          │
          ▼
可编程 SmartNIC
  flow steering / tunnel / meter / crypto / P4 或 FPGA
          │
          ▼
DPU / IPU
  独立控制面 + 可编程数据面 + 固定功能加速器
  承载网络、存储、安全、遥测和设备虚拟化
```

这条演进路径不是替换关系。生产环境往往同时使用三层能力：

- 固定功能硬件处理规则明确、吞吐稳定的工作；
- 可编程流水线处理分类、封装、策略和流表；
- DPU 上的 CPU 负责异常路径、控制协议、编排代理和慢速服务。

把所有包都送到 DPU 的通用 CPU 上，并不会自动获得线速。

### 1.2 为什么很多先进架构先从网络出现

表面上看，NIC 只是一个 I/O 外设；但在数据中心里，它恰好位于计算系统与外部世界的
交界处。流量进入主机之前，已经需要完成分类、调度、隔离、加密、可观测性和租户策略。
随着这些职责增加，NIC 最终不再只是“收发包的设备”，而是逐步具备了独立机器的要素：

```text
网卡
  └─ 固定功能卸载
       └─ 可编程数据面
            └─ 独立 CPU、内存和操作系统
                 └─ 网络、存储、安全与管理基础设施
```

很多先进概念从网络开始，主要有四个原因：

- **外部交互的数据移动成本高**：包在 NIC、内核、用户态、VM 和应用之间每多走一步，
  都会消耗 PCIe、内存带宽、cache 和 CPU cycles。网络路径因此最早暴露
  “计算不贵、搬运昂贵”的问题。
- **网络入口是天然的策略执行点**：ACL、QoS、租户隔离、加密和遥测都可以在流量
  进入主机前执行。策略越早执行，后续系统需要处理的无效或不可信数据就越少。
- **网络是故障域与信任域的边界**：如果基础设施策略运行在租户可控制的 host 上，
  隔离强度会受到 host OS 和 hypervisor 的限制。独立 DPU 可以建立一条 host 难以
  绕过的管理与安全路径。
- **网络工作负载结构化且易于流水线化**：报文头、流表、队列和动作天然适合固定功能
  引擎与可编程流水线。网络因此比通用计算更容易先获得专用硬件收益。

这也解释了为什么网络技术会向相邻领域扩张：当 NIC 已经拥有独立处理器、内存、
DMA 和可信启动链后，继续承接 NVMe-oF、加密、遥测和设备虚拟化，比在主机上
再建立一套基础设施服务更自然。

---

## 2. DPDK 在新架构中的位置

### 2.1 传统 host 数据面

```text
VM / Container
      │ virtio / vhost-user
      ▼
OVS-DPDK / VPP / 自研 DPDK 应用
      │ PMD
      ▼
物理 NIC
```

优点是软件灵活、调试路径清晰；代价是占用 host 核、内存带宽和 hugepage，
基础设施服务还会与租户业务争抢缓存和 NUMA 资源。

### 2.2 DPU 数据面

```text
Host CPU                                   DPU / IPU
┌──────────────────┐       PCIe       ┌────────────────────────┐
│ VM / Container   │◄────────────────►│ virtio / SR-IOV 前后端 │
│ 业务应用         │                  │ OVS / DPDK / 控制代理  │
└──────────────────┘                  │ flow / crypto / storage│
                                      └───────────┬────────────┘
                                                  │
                                                  ▼
                                            物理网络端口
```

这里的 DPDK 可能出现在三个位置：

1. **DPU CPU 上**：运行 OVS-DPDK、VPP、testpmd 或自研服务。
2. **host 上**：处理 DPU 暴露的 representor、SF、VF 或 virtio 设备。
3. **控制与验证工具中**：生成流量、验证 offload、读取统计和构造回退路径。

### 2.3 “卸载成功”不能只看流表创建成功

一条规则从软件下发到硬件，不代表整个数据路径都已卸载。至少要检查：

```text
规则是否进入硬件
  ├─ flow counter 是否在硬件侧增长
  ├─ miss / exception 是否回到软件慢路径
  ├─ 首包、分片、邻居解析和控制报文由谁处理
  ├─ conntrack / NAT / meter 状态存在哪里
  └─ 设备复位或热迁移后状态如何恢复
```

最危险的场景不是完全没有卸载，而是 **大部分流量卸载、少量异常流量压垮慢路径**。

---

## 3. 2026 年主流产品：只比较可验证能力

下表以厂商公开资料为准。端口组合、板卡内存、功耗和可用功能会因 SKU、
固件及软件许可不同而变化，因此不使用单一价格或“生态成熟度”分数。

| 平台                  | 通用计算                                           | 网络能力                             | 主机接口       | 主要定位                               |
| --------------------- | -------------------------------------------------- | ------------------------------------ | -------------- | -------------------------------------- |
| NVIDIA BlueField-3    | 16 个 Arm A78 核                                   | 最高 400 Gb/s，具体取决于板卡        | PCIe Gen5 x16  | 网络、存储、安全和虚拟化基础设施卸载   |
| NVIDIA BlueField-4    | 64 核 Grace CPU，Arm Neoverse V2                   | 最高 800 Gb/s                        | PCIe Gen6 路线 | 面向 AI 工厂的下一代基础设施平台       |
| Intel IPU E2100       | Arm Neoverse N1 compute complex                    | 200GbE 产品系列                      | PCIe Gen4 x16  | 云基础设施隔离、虚拟网络和远端存储     |
| AMD Pensando DSC2-200 | Elba P4 可编程 DPU                                 | 双 QSFP56，支持 2×40/100/200G 等组合 | PCIe Gen4 x16  | 分布式网络、安全、可观测性和 NVMe 服务 |
| AWS Nitro             | 自研卡、Security Chip 与轻量 hypervisor 的系统组合 | 随 EC2 代际演进                      | 云内部实现     | 将网络、EBS、安全和管理能力移出主系统  |
| Microsoft Azure Boost | 自研硬件与软件系统                                 | 云内部实现                           | 云内部实现     | 网络和存储基础设施卸载                 |

### 3.1 对原有产品表的关键纠正

- **Intel E2100 不是“16 × Xeon-D”**。Intel 官方资料明确写的是 Arm Neoverse N1
  compute complex。IPU 这个名字不能用来推断处理器 ISA。
- **BlueField-4 是 DPU，不是 BlueField-3 的简单“SuperNIC 版本”**。NVIDIA 在
  2025 年公布 BlueField-4，公开架构为 64 核 Grace CPU 加 ConnectX-9，最高 800 Gb/s。
- **Pensando DSC2-200 不是 100G 固定规格**。官方产品简报给出的端口组合包括
  `2×40/100/200G`，并支持 breakout。
- AWS Nitro 和 Azure Boost 是云平台级系统，不能像零售 PCIe 卡一样仅按核数和端口横评。
- 未公开合同价、客户部署规模和完整 SKU 数据不应写成确定事实。

### 3.2 选型先问六个问题

1. 目标是释放 CPU 核、建立独立信任域，还是增加端口吞吐？
2. 需要卸载的是 L2/L3、overlay、conntrack/NAT、IPsec/TLS，还是 NVMe？
3. 规则规模、更新速率和异常流量比例是多少？
4. 现有编排依赖 OVS/OVN、Kubernetes、OpenStack，还是自研控制面？
5. 是否要求热迁移、双机高可用、在线升级和故障回退？
6. 团队能否维护第二套操作系统、固件、SDK 和可观测性链路？

> [!tip] 实用判断
> 如果瓶颈只是单个 DPDK worker 没有做好 NUMA、批处理或 flow offload，
> 先调优现有路径通常比引入 DPU 更便宜。
> DPU 的主要价值是 **隔离、可运营性和规模化基础设施卸载**，而不只是跑分。

---

## 4. Host 与 DPU 之间到底怎样通信

“共享内存 + 零拷贝”只是目标，不是默认事实。具体路径取决于设备模型和 DMA 能力。

### 4.1 常见设备模型

| 模型                 | Guest/Host 看到什么 | 后端在哪里                  | 适用场景                       |
| -------------------- | ------------------- | --------------------------- | ------------------------------ |
| virtio + 软件 vhost  | virtio 设备         | host 或 DPU 上的软件进程    | 灵活、兼容性好                 |
| vDPA                 | 标准 virtio 设备    | 硬件或硬件辅助后端          | 保持 virtio 语义并减少软件搬运 |
| SR-IOV VF            | PCIe VF             | NIC/DPU 硬件                | 低开销、强依赖设备状态管理     |
| representor / SF     | 可管理的端口表示    | switchdev / embedded switch | OVS/TC/DPDK 管理硬件交换路径   |
| 厂商专用共享内存通道 | 专用设备或 API      | DPU runtime                 | 极低开销，但可移植性较弱       |

### 4.2 零拷贝成立的条件

要把“零拷贝”写进设计目标，至少需要同时确认：

- IOMMU 映射允许目标设备 DMA 到该内存；
- 内存生命周期长于所有未完成 DMA；
- 页被 pin 住，地址不会在 DMA 期间失效；
- cache coherency 与 memory ordering 满足设备要求；
- buffer ownership 在 host、DPU、NIC 和 guest 之间没有歧义；
- 多段 mbuf、headroom、offload metadata 均被后端支持。

否则所谓零拷贝可能退化为 bounce buffer、软件重组或隐式复制。

---

## 5. 机密计算为什么会改变 DPDK 数据路径

机密计算的核心不是“给 VM 内存加密”这么简单，而是把 hypervisor 从默认可信方
降为潜在不可信方。当前主要 VM 级技术包括 AMD SEV-SNP、Intel TDX 和 Arm CCA Realm。

| 技术        | 保护对象      | 关键机制                        | DPDK 关注点                       |
| ----------- | ------------- | ------------------------------- | --------------------------------- |
| AMD SEV-SNP | VM 内存与状态 | 内存加密、完整性保护、证明      | 私有页与共享 DMA 页的转换         |
| Intel TDX   | Trust Domain  | TDX module、私有/共享内存、证明 | virtio/MMIO 与 DMA 必须使用共享页 |
| Arm CCA     | Realm         | RME、RMM、Realm world           | Realm 与设备的可信 I/O 路径       |

### 5.1 私有内存和共享内存的矛盾

以 TDX 为例，私有页对 hypervisor 不可见；但传统 virtio 后端、vhost-user 或物理设备
必须能够读取 descriptor 和 packet buffer。于是数据路径通常需要显式共享：

```text
机密 VM 私有内存
  ├─ 代码、密钥、业务状态：保持 private
  └─ virtqueue / DMA buffer：转换为 shared
                             │
                             ▼
                    hypervisor / vhost / device
```

这带来一个容易被忽略的结论：

> 机密 VM 保护的是被声明为私有的内存。放入共享 DMA 区域的数据，
> 不能继续假设对 host 或设备不可见。

### 5.2 DPDK 应用需要重新检查的内容

1. **mempool 放在哪里**：整个 hugepage 区共享，还是仅共享收发缓冲区？
2. **敏感数据何时解密**：进入共享 mbuf 前，还是复制到私有内存后？
3. **virtio 后端是否可信**：在 host、独立 DPU，还是受证明的设备域中？
4. **VF passthrough 的威胁模型**：设备、固件和 IOMMU 是否属于可信计算基？
5. **远程证明如何接入控制面**：证明通过前是否允许下发密钥和流量？
6. **迁移与恢复**：证明身份、内存密钥和设备状态如何在目标节点重建？

### 5.3 不要给出统一“性能损耗百分比”

SEV-SNP、TDX 或 CCA 对 DPDK 的影响高度依赖：

- 包大小、突发长度和队列数；
- virtio、vhost-user、vDPA 或 VF passthrough 路径；
- 共享页转换、SWIOTLB 和 bounce buffer；
- 内存带宽、NUMA、IOMMU 和中断模式；
- 是否在数据路径中执行加密、证明或额外复制。

因此“固定损耗 5%”或“延迟只增加 100ns”没有普适意义。可靠做法是给出测试矩阵：

```text
baseline:
  普通 VM + 相同 vCPU / NUMA / NIC / queue 配置

variant:
  机密 VM + 相同业务配置

measure:
  Mpps / Gbit/s
  p50 / p99 / p99.9 latency
  host 与 guest CPU cycles
  shared/private page conversion
  IOMMU faults / SWIOTLB usage
  packet loss 与 slow-path rate
```

---

## 6. SPDK 与 DPU：不是“DPDK 的存储版本”

DPDK 和 SPDK 都强调用户态、轮询、批处理和 NUMA 感知，但两者并不共享“一套 PMD
和 lock-free 队列”。现代 SPDK 有自己的环境抽象、线程模型、bdev 和 NVMe-oF 子系统，
可使用 DPDK 提供部分底层环境能力，也可采用其他实现。

### 6.1 典型存储卸载路径

```text
Guest
  │ virtio-blk / virtio-scsi / NVMe VF
  ▼
DPU storage backend
  │ policy / crypto / QoS / translation
  ▼
SPDK initiator or target
  │ NVMe-oF RDMA / TCP
  ▼
远端存储集群
```

DPU 在这里可以承担：

- 向 host/guest 模拟标准块设备或 NVMe VF；
- 终止、转换或发起 NVMe-oF；
- 执行加密、压缩、QoS 和多路径；
- 将存储控制面与不可信租户隔离。

### 6.2 评价存储卸载要看尾延迟和故障语义

“接近本地 NVMe”不能只看顺序吞吐。至少还要测：

- 4 KiB 随机读写的 IOPS 与 p99.9 延迟；
- 网络抖动、丢包和拥塞时的超时行为；
- target 切换和链路故障时是否重复完成 I/O；
- 队列深度升高后的 CPU、内存和 PCIe 带宽；
- DPU 重启、升级及控制面失联后的恢复时间。

---

## 7. virtio 1.2：不要把规范版本和实现特性混在一起

原文将 packed virtqueue 写成 virtio 1.2 的新特性，这是不准确的。

| 版本       | 关键事实                                                     |
| ---------- | ------------------------------------------------------------ |
| virtio 1.0 | OASIS 标准化后的现代 virtio 基线                             |
| virtio 1.1 | 引入 packed virtqueue 等能力                                 |
| virtio 1.2 | 增加 virtqueue reset、管理设备等规范能力，并整合大量设备改进 |

virtio 1.2 规范同时定义 split virtqueue 与 packed virtqueue。
packed layout 将 descriptor、available/used 状态组织得更紧凑，可减少部分缓存访问，
但它 **不保证固定的 30% 或 50% 性能提升**。

实际结果取决于：

- 前后端是否都实现并协商 `VIRTIO_F_RING_PACKED`；
- in-order、event suppression、batch size 和 notification 策略；
- vhost、vDPA 或硬件实现；
- cacheline、NUMA 和队列竞争；
- 多段包、mergeable buffer 和 offload 组合。

### 7.1 验证 packed virtqueue 是否真的生效

```text
1. 检查 QEMU/设备是否暴露 packed ring 能力
2. 检查 guest 驱动是否协商 VIRTIO_F_RING_PACKED
3. 检查后端日志或设备统计确认使用 packed path
4. 用相同 CPU 亲和性和队列配置做 split/packed A/B 测试
5. 同时记录吞吐、尾延迟、CPU cycles 和丢包
```

---

## 8. GPU、NIC 与 DPDK：重点是内存注册和所有权

DPDK 的 `gpudev` 库提供通用 GPU 接口。支持该能力的设备可以使用 GPU 内存作为
external mbuf 的数据区，使 NIC 直接向 GPU 内存收发数据。

```text
NIC
 │ DMA
 ▼
GPU memory backed external mbuf
 │
 ▼
CUDA / 推理或数据处理 kernel
```

这条路径可能减少 CPU 搬运，但不是“调用 `cudaMalloc` 后直接 `rx_burst`”这么简单。
工程上必须处理：

- GPU 内存分配与 DPDK external memory 注册；
- NIC 对 GPU 内存的 DMA map；
- external mbuf 的创建、引用计数和释放；
- NIC、CPU、GPU 之间的生产者/消费者同步；
- 不支持 GPU memory 的包头、metadata 或 fallback buffer；
- GPUDirect RDMA、PCIe 拓扑和 IOMMU 的平台限制。

### 8.1 DPU 在 AI 集群中的真实价值

DPU/SuperNIC 对 AI 系统的价值通常不是在网卡上执行主模型推理，而是：

- 隔离租户网络和基础设施服务；
- 执行 RoCE、拥塞控制、加密和遥测；
- 卸载存储访问与数据移动；
- 减少 host CPU 对 GPU 通信路径的干扰；
- 为 GPU 集群提供可预测的网络和故障域。

---

## 9. DPDK 版本现状：截至 2026-06-09

原文的“24-25 LTS 路线图”已经过时，而且将多个并不存在的版本特性写成事实。

| 项目             | 当前状态                                            |
| ---------------- | --------------------------------------------------- |
| 最新正式版       | DPDK 26.03.0，发布于 2026-03-31                     |
| 最新 LTS         | DPDK 25.11.2                                        |
| 下一计划版本     | DPDK 26.07.0，路线图日期为 2026-07-16               |
| 25.11 的代表变化 | 800G link speed、跨进程/跨 OS DMA API、驱动与库更新 |

选择版本时应遵循：

- 新项目若需要最新设备支持，可评估 26.03；
- 生产系统若看重稳定分支和回补修复，优先评估 25.11 LTS；
- 不要只看主版本号，还要核对 PMD、固件、rdma-core、内核和厂商 SDK 的兼容矩阵；
- DPU 上的 DPDK 通常受 BSP/DOCA/固件组合约束，不能随意替换为任意上游版本。

---

## 10. 未来五年：哪些是事实，哪些只是判断

### 10.1 高确定性趋势

1. **基础设施服务继续离开 host CPU**
   网络、存储、安全和遥测会更多使用独立处理器与硬件流水线。

2. **DPDK 与硬件卸载长期共存**
   DPDK 仍负责软件回退、控制协同、通用数据面和设备抽象。

3. **virtio 仍是重要的跨实现设备接口**
   vDPA、硬件 virtio backend 和管理设备会继续降低软件模拟成本。

4. **可信 I/O 成为机密计算的关键瓶颈**
   只保护 CPU 内存而不解决设备 DMA、共享页和证明链，无法形成完整可信数据路径。

5. **AI 基础设施推动更高网络带宽和更强可观测性**
   800G 及更高速率会进入 DPDK API 和驱动，但端口速率不等于应用有效吞吐。

### 10.2 中等确定性判断

- 主机上的通用 OVS-DPDK 用量可能下降，但 DPU、边缘节点和专用网络功能中的
  DPDK 用量仍会增长。
- eBPF/XDP 会覆盖更多内核集成和中等吞吐场景，不会自动替代需要用户态设备控制、
  跨平台 PMD 或极致批处理的数据面。
- P4 更适合描述受约束的流水线；复杂状态机、控制协议和异常路径仍需要通用软件。
- Rust 会更多进入控制面和安全敏感组件，但短期内不会整体替换 DPDK 的 C ABI。

### 10.3 不应写成事实的预测

以下说法缺少统一公开数据，不宜直接下结论：

- “某年所有云厂商 100% 部署 DPU”；
- “5G UPF 默认全部运行在 DPU”；
- “主机 DPDK 到 2030 年只剩少量”；
- “eBPF 与 DPDK 固定相差 2～3 倍”；
- “DPU 能让所有工作负载提升 10 倍”。

技术趋势可以判断，但比例、年份和性能必须绑定具体样本与测试条件。

---

## 11. 一套可执行的 DPU / DPDK PoC 方法

### 11.1 先建立 baseline

```text
硬件:
  CPU / NUMA / 内存通道 / PCIe 拓扑 / NIC 固件

软件:
  kernel / DPDK / rdma-core / OVS 或 VPP / DPU BSP

数据面:
  包长 / 流数 / queue 数 / burst / offload / MTU

指标:
  吞吐 / p50-p99.9 延迟 / 丢包 / CPU cycles / 功耗
```

### 11.2 再逐层增加能力

1. host 软件转发；
2. host 上启用硬件 flow offload；
3. DPU 接管网络数据面；
4. 增加 conntrack、NAT、IPsec 或存储服务；
5. 增加故障注入、热升级和控制面失联测试；
6. 最后评估机密 VM 或 GPU memory direct path。

每一步只改变一个主要变量，否则无法判断收益来自哪里。

### 11.3 必测的失败场景

- 规则容量耗尽；
- 未命中流量突增；
- DPU CPU 满载；
- DPU OS 或固件重启；
- PCIe reset / link flap；
- 控制器断连；
- 软件与硬件状态不一致；
- 加密密钥轮换；
- 迁移后 flow、queue 和统计恢复；
- GPU/DMA buffer 在异常退出时的回收。

---

## 12. 总结

理解 DPU 和下一代虚拟化，最重要的不是记产品参数，而是区分四个问题：

```text
谁拥有基础设施控制权？
数据包实际经过哪些处理单元？
哪部分内存和设备属于可信计算基？
故障、升级和迁移时状态怎样恢复？
```

DPDK 的未来也由这四个问题决定：

- 在 host 上，它仍是高性能通用数据面的基础；
- 在 DPU 上，它连接通用 CPU、硬件流水线与虚拟设备；
- 在机密计算中，它必须显式处理 private/shared memory 边界；
- 在 GPU 和存储路径中，它负责一部分内存、队列和 DMA 协同。

因此，更准确的结论不是“DPDK 从 host 迁移到 DPU”，而是：

> **DPDK 正从单机高速收发框架，演进为异构基础设施中的数据面组件。**

---

## 参考资料

### DPU / IPU

- [NVIDIA BlueField-3 DPU specifications](https://docs.nvidia.com/networking/display/BlueField3DPU/Specifications)
- [NVIDIA BlueField-4 architecture overview](https://developer.nvidia.com/blog/inside-the-nvidia-rubin-platform-six-new-chips-one-ai-supercomputer/)
- [Intel IPU Adapter E2100](https://www.intel.com/content/www/us/en/products/details/network-io/ipu/adapter-e2100.html)
- [AMD Pensando DSC2-200 product brief](https://www.amd.com/content/dam/amd/en/documents/pensando-technical-docs/product-briefs/pensando-dsc-200-product-brief.pdf)
- [AWS Nitro System](https://aws.amazon.com/ec2/nitro/)
- [Microsoft Azure Boost](https://learn.microsoft.com/en-us/azure/azure-boost/)

### 规范与软件

- [OASIS Virtual I/O Device (VIRTIO) Version 1.2](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
- [DPDK downloads and current releases](https://core.dpdk.org/download/)
- [DPDK roadmap](https://core.dpdk.org/roadmap/)
- [DPDK 25.11 release notes](https://doc.dpdk.org/guides-25.11/rel_notes/release_25_11.html)
- [DPDK GPU library](https://doc.dpdk.org/guides/prog_guide/gpudev.html)
- [SPDK documentation](https://spdk.io/doc/)

### 机密计算

- [QEMU confidential guest support](https://qemu.readthedocs.io/en/latest/system/confidential-guest-support.html)
- [Linux kernel: Intel TDX](https://www.kernel.org/doc/html/latest/x86/tdx.html)
- [Linux kernel: confidential computing threat model](https://www.kernel.org/doc/html/latest/security/snp-tdx-threat-model.html)
- [Arm Confidential Compute Architecture](https://www.arm.com/architecture/security-features/arm-confidential-compute-architecture)
