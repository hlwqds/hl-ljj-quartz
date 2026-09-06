---
title: "DPDK 深度探索 ch37b：SmartNIC 数据面——Representor、E-Switch 与硬件卸载"
date: 2026-04-09 16:20:00
tags: [dpdk, smartnic, dpu, ipu, representor, eswitch, rte-flow, switchdev, bluefield, pensando]
description: "从 DPDK 工程视角解析 SmartNIC/DPU：embedded switch、PF/VF/SF representor、rte_flow transfer、慢路径与硬件快路径、BlueField/IPU/Pensando 定位、资源管理、故障恢复和可验证 PoC"
---

# DPDK 深度探索 ch37b：SmartNIC 数据面——Representor、E-Switch 与硬件卸载

> [!info] 章节定位
> 系列中已有 [[ch37-tls-dpdk|第三十七章：TLS 与 DPDK]]，
> 因此本文按 **ch37b 专题章**处理。
>
> 资料与 API 核对日期：**2026-06-09**，DPDK 基线为 26.03。

> [!abstract] 核心结论
> SmartNIC 的关键不是“网卡上多了几个 CPU 核”，而是网卡内部出现了一个可管理的
> **embedded switch（E-Switch）**，并逐步拥有独立计算、内存、操作系统和信任域。
>
> 对 DPDK 应用而言，真正需要掌握的是：
>
> 1. PF、VF、SF、物理端口和 host/DPU 之间如何连接；
> 2. representor 如何把硬件端口暴露给软件控制面；
> 3. `rte_flow` 如何把软件观察到的流量转入硬件快路径；
> 4. miss、exception、老化、容量耗尽和设备复位时怎样回退；
> 5. 如何证明“规则创建成功”确实等于“数据包命中硬件”。

> [!info] 关联章节
>
> - [[ch19b-dpu-smartnic|DPU/SmartNIC 入门]]
> - [[ch35-virtualization-future|DPU、机密计算与异构 I/O]]
> - [[ch35-sr-iov|SR-IOV 与 VF 管理]]
> - [[ch36-p4-dpdk|P4 与 DPDK SWX]]
> - [[ch41-doca-comparison|NVIDIA DOCA]]

---

## 1. 为什么 NIC 最终变成了一台独立机器

网络位于计算系统与外部世界的交界处。数据进入 host 前，通常已经需要完成：

```text
分类 → 租户隔离 → ACL → tunnel → QoS → 加密 → 遥测 → 转发
```

这些工作具有四个特点：

- 每个包都要执行，数据移动成本高；
- 规则结构化，适合流水线和专用硬件；
- 越早丢弃无效流量，越少浪费 host 资源；
- 网络入口天然是安全与故障边界。

于是 NIC 的演进不是单纯增加端口速率，而是不断吸收基础设施职责：

```text
传统 NIC
  checksum / RSS / TSO
        │
        ▼
可编程 SmartNIC
  parser / match / action / tunnel / meter
        │
        ▼
DPU / IPU
  独立 CPU + 内存 + OS + secure boot
  网络 + 存储 + 安全 + 虚拟化控制
```

这也解释了“说是 NIC，最后却像一台独立机器”：当外部交互的策略、状态和信任边界
都集中到 I/O 入口时，为它增加独立控制面和故障域比继续占用 host 更自然。

很多先进系统概念也确实先在网络中规模化出现，例如：

- 多租户隔离与零信任；
- 可编程 match-action pipeline；
- control plane 与 data plane 分离；
- service chaining；
- 流式遥测与在线策略更新；
- SmartNIC/DPU 形成的异构计算。

原因并不玄学。网络同时具备高数据量、强并行、明确协议边界和巨大的数据移动成本。
只要能在入口提前完成一次分类、丢弃或转发，就可能省掉后续 CPU、内存、PCIe 和缓存访问。
因此网络不是“更容易创新”，而是优化收益更容易被端到端测量。

### 1.1 SmartNIC、DPU、IPU 不是严格标准

| 名称          | 通常强调                       | 不能据此推断             |
| ------------- | ------------------------------ | ------------------------ |
| SmartNIC      | 可编程网络数据面               | 一定有完整 Linux         |
| DPU           | 网络、存储、安全等基础设施服务 | 所有包都由 Arm CPU 处理  |
| IPU           | 基础设施隔离与运营             | CPU 一定是 x86           |
| FPGA SmartNIC | 可重构逻辑与专用 pipeline      | 与 ASIC 具有相同资源模型 |

厂商名称不是能力证明。选型必须落到具体 SKU、固件、PMD、SDK 和 capability。

---

## 2. SmartNIC 的核心：Embedded Switch

传统 SR-IOV NIC 已经包含一个内部交换模块，用于连接：

- 物理端口；
- PF；
- VF；
- 某些设备支持的 SF；
- host 与 DPU embedded CPU 侧功能。

在 SmartNIC/DPU 中，这个内部交换模块通常可被软件定义规则控制：

```text
                         SmartNIC / DPU
       ┌───────────────────────────────────────────────┐
wire ─┤ physical port                                 │
       │       │                                       │
       │  ┌────▼──────────────────────────────────┐    │
       │  │          Embedded Switch              │    │
       │  │  match / modify / encap / count       │    │
       │  └─┬──────────┬──────────┬──────────┬────┘    │
       │    │          │          │          │         │
       │   PF         VF0        VF1         SF0        │
       │    │          │          │          │         │
       └────┼──────────┼──────────┼──────────┼─────────┘
            │          │          │          │
         manager     VM A       VM B      service
```

### 2.1 Legacy 与 switchdev

Linux devlink 常把 E-Switch 模式分为：

- **legacy**：以传统 MAC/VLAN 和 SR-IOV 行为为主；
- **switchdev**：允许 Linux bridge、TC flower、OVS 等控制高级硬件规则，并创建
  VF/SF representor。

```bash
devlink dev eswitch show pci/0000:08:00.0

devlink dev eswitch set pci/0000:08:00.0 \
  mode switchdev \
  inline-mode none \
  encap-mode basic
```

并非所有设备、PMD 或部署都使用 Linux switchdev，但它描述了一个重要模型：
**物理/虚拟端口由软件表示，转发规则由控制面下发到 E-Switch。**

---

## 3. Representor：软件看到的“硬件端口代理”

### 3.1 为什么需要 representor

假设 VF0 分配给 VM A。VM A 发出的包进入 E-Switch，但 hypervisor 上的 OVS/DPDK
需要先观察、分类并决定是否卸载这条流。

representor 是 VF0 在管理平面一侧的代理端口：

```text
VM A
  │ VF0
  ▼
E-Switch ───────── wire
  ▲
  │ VF0 representor
  ▼
OVS / DPDK control and slow path
```

它不是 VF 本身，也不是简单镜像：

- represented port 是 E-Switch 另一侧的真实端点；
- representor 是管理应用用于收包、注包和配置 steering 的软件端口；
- 硬件规则建立后，大部分包可以不再经过 representor 的软件 RX/TX。

DPDK 文档把 representor 类比为软件”配线架”的前端。

### 3.2 Representor 在内核里长什么样

上面说的是 representor 的概念。在 Linux 系统中，representor 有一个具体的形态：
**它就是一个内核网络接口（netdev）**。

当 NIC 的 E-Switch 切换到 switchdev 模式后，内核会为每个 VF 自动创建一个
representor netdev。用 `ip link` 可以直接看到：

```bash
# 查看所有 representor 接口
ip -d link show | grep -A2 representor

# 典型输出
3: enp8s0f0: <BROADCAST,MULTICAST,UP> ... # PF（物理功能）
4: enp8s0f0v0: <BROADCAST,MULTICAST> ...   # VF0 representor
5: enp8s0f0v1: <BROADCAST,MULTICAST> ...   # VF1 representor
6: enp8s0f0v2: <BROADCAST,MULTICAST> ...   # VF2 representor
```

每个 representor netdev 对应 E-Switch 内部的一个 VF 端口：

```text
                  Linux 内核
    ┌──────────────────────────────────┐
    │                                  │
    │  enp8s0f0v0   enp8s0f0v1        │
    │  (VF0 repr)   (VF1 repr)        │
    │      │            │              │
    └──────┼────────────┼──────────────┘
           │            │
    ┌──────▼────────────▼──────────────┐
    │        Embedded Switch           │
    │    (硬件内部的转发表)              │
    └──┬──────┬──────┬──────┬─────────┘
       │      │      │      │
      PF    VF0    VF1    wire
              │      │
            VM A   VM B
```

关键点：

- **VF 本身在 VM 内部有自己的 netdev**（比如 `eth0`），hypervisor/宿主机看不到
- **VF representor 在宿主机内核里**，是宿主机访问这个 VF 流量的唯一入口
- VF0 和 VF0 representor 不是同一个接口——VF0 在 VM 里，representor 在宿主机里
- representor netdev 的 `phys_switch_id` 和 `phys_port_name` 属性可以用来
  关联它代表的 VF

```bash
# 确认 representor 对应关系
ethtool -i enp8s0f0v0
cat /sys/class/net/enp8s0f0v0/phys_switch_id
cat /sys/class/net/enp8s0f0v0/phys_port_name
# 输出类似：pf0vf0
```

有了这个内核接口，**内核态的网络栈就能看到和控制 VF 的流量**：

- **OVS** 可以把 representor 加入 bridge port，用 OpenFlow 规则控制 VF 流量
- **TC flower** 可以在 representor 上挂载硬件卸载规则（`tc filter ... dev enp8s0f0v0 ...`）
- **Linux bridge** 可以把多个 representor 加入同一个网桥实现 L2 转发
- **tcpdump** 可以在 representor 上抓包，观察 VF 的首包和异常流量

```bash
# 用 TC flower 在 representor 上卸载一条规则
tc qdisc add dev enp8s0f0v0 ingress
tc filter add dev enp8s0f0v0 protocol ip ingress flower \
  src_ip 10.0.0.1 dst_ip 10.0.0.2 \
  action mirred egress redirect dev enp8s0f0  # 转发到 PF（uplink）
```

这也是 switchdev 模式的核心价值：**让 Linux 内核已有的网络工具（OVS、TC、bridge、
tcpdump）能像管理普通网卡一样管理 SmartNIC 上的 VF 流量**，而不需要每个工具
单独适配硬件厂商的私有 API。

### 3.3 两种访问方式：内核 netdev 与 DPDK ethdev

同一个 representor 硬件端口可以有两种访问方式：

| 维度     | 内核 netdev              | DPDK ethdev                   |
| -------- | ------------------------ | ----------------------------- |
| 访问方式 | 标准网络接口             | PMD devargs `representor=vfN` |
| 控制工具 | OVS、TC、bridge、tcpdump | rte_flow、testpmd             |
| 适用场景 | 内核态控制面、OVS 卸载   | 用户态高速数据面、自研控制面  |
| 规则接口 | TC flower / OVS kernel   | rte_flow (transfer)           |
| 共存     | 同一时刻通常只用一种     | 取决于 PMD 和驱动模型         |

在 bifurcated driver 模型（如 mlx5）下，内核驱动管理设备生命周期，DPDK PMD
通过用户态接口使用数据路径。两者可以协同但不能对同一个 representor 同时独立下发
冲突规则。

### 3.5 在 DPDK 中发现 representor

PMD 通常通过 devargs 创建指定 representor：

```bash
-a 0000:08:00.0,representor=vf0
-a 0000:08:00.0,representor=vf[0-3]
-a 0000:08:00.0,representor=sf[0-31]
```

应用不应假设 DPDK `port_id` 等于 VF 编号。应查询：

- `RTE_ETH_DEV_REPRESENTOR` device flag；
- `rte_eth_switch_info.domain_id`；
- `rte_eth_switch_info.port_id`；
- representor 类型与其 represented entity。

同一 embedded switch 中的端口共享 switch domain，但应用层 port index 仍可能动态变化。

### 3.6 最容易混淆的收发方向

应从“数据包进入 embedded switch 的哪一侧”理解方向，而不是从 representor 的名字猜：

| 数据包来源       | 在 switch 中的含义               | 软件观察位置                   |
| ---------------- | -------------------------------- | ------------------------------ |
| VF0 发包         | 从 represented VF0 进入 switch   | VF0 representor 的管理侧 RX    |
| wire 收包        | 从 physical port 进入 switch     | uplink/physical representor RX |
| 软件向 VF0 注包  | 从 representor 管理侧进入 switch | action 指向 represented VF0    |
| 软件向 wire 注包 | 从 uplink 管理侧进入 switch      | action 指向 physical endpoint  |

`represented_port` 和 `port_representor` 也不能互换：

- `represented_port` 指 representor 背后的真实 VF/SF/PF endpoint；
- `port_representor` 指管理该 endpoint 的 representor ethdev 一侧。

具体支持和命名仍以 PMD capability 为准。调试时应先安装只带 `count` 或 `drop`
的规则确认方向，再加入转发、改包和 tunnel action。

### 3.7 Representor 数量本身也会成为成本

大量 VF/SF representor 可能带来：

- 每端口 RX/TX queue 和 descriptor 内存；
- 轮询端口数量增加；
- cache miss 与调度延迟；
- 初始化和 reset 时间增长；
- flow 与统计对象数量增长。

DPDK 提供 shared RX queue capability，让同一 RX domain 的多个 representor 共享队列。
使用时收到的 `mbuf.port` 用于标识来源，应用必须正确分发。

---

## 4. 从慢路径到硬件快路径

SmartNIC offload 最常见的工作方式不是“启动时把所有未来流量都编程好”，而是：

```text
first packet / miss
        │
        ▼
representor slow path
        │
        ├─ classify
        ├─ policy / route / conntrack
        ├─ decide actions
        └─ create hardware rule
                 │
                 ▼
subsequent packets hit E-Switch fast path
```

### 4.1 一条 flow 的生命周期

```text
MISS
  │ 首包送软件
  ▼
PENDING
  │ 计算策略、分配 counter/modify/tunnel 对象
  ▼
VALIDATING
  │ rte_flow_validate
  ▼
ACTIVE
  │ rte_flow_create 成功并确认硬件命中
  ▼
AGED / EVICTED / ERROR
  │ 回收状态或重新下发
  ▼
DESTROYED
```

控制面必须考虑规则创建期间的包：

- 缓存首包；
- 暂时走软件；
- 允许轻微重排；
- 或在规则 commit 后重放。

不同选择会影响延迟、顺序和连接状态。

### 4.2 `rte_flow` 的角色

一条规则由三部分组成：

```text
attributes:
  ingress / egress / transfer / group / priority

pattern:
  represented port / Ethernet / VLAN / IP / tunnel / L4 ...

actions:
  count / modify / encap / decap / sample / jump /
  represented port / physical port / queue / drop ...
```

应用必须先调用 `rte_flow_validate()`。即使语法正确，规则也可能因为当前设备模式、
queue 配置、组合限制或资源不足而失败。

### 4.3 `transfer` 的含义

普通 ingress flow 处理进入某个 ethdev 的流量；`transfer` 规则则作用于
embedded switch domain 中端点之间的传输路径，例如：

```text
VF0 → physical port
physical port → VF1
VF0 → VF1
```

端口 representor、represented port item/action 和 transfer 支持因 PMD 而异。
不能把某个 mlx5 示例直接复制到所有 SmartNIC。

### 4.4 规则成功创建不等于成功卸载

至少验证：

- 硬件 counter 是否随目标流量增长；
- representor software RX 是否下降；
- miss/exception counter 是否异常增长；
- rule query 是否显示正确命中；
- CPU cycles 是否下降；
- 包实际从预期 endpoint 发出；
- 删除规则后流量是否回到 slow path。

如果只有控制面日志显示 `rte_flow_create()` 成功，还不足以证明数据面走了硬件。

### 4.5 用 testpmd 建立最小 transfer 规则

假设：

- DPDK port 3 是 VF0 representor；
- DPDK port 4 是 VF1 representor；
- 两者属于同一个 switch domain。

先验证规则：

```text
testpmd> flow validate 3 transfer pattern represented_port ethdev_port_id is 3 / end actions count / represented_port ethdev_port_id 4 / end
```

再创建 VF0 → VF1 的规则：

```text
testpmd> flow create 3 transfer pattern represented_port ethdev_port_id is 3 / end actions count / represented_port ethdev_port_id 4 / end
```

反向规则需要单独创建：

```text
testpmd> flow create 3 transfer pattern represented_port ethdev_port_id is 4 / end actions count / represented_port ethdev_port_id 3 / end
```

查看、查询和删除：

```text
testpmd> flow list 3
testpmd> flow query 3 0 count
testpmd> flow destroy 3 rule 0
```

这里的 `3` 既可能是规则下发所依附的 ethdev，也恰好是一个 representor。
它不意味着所有 PMD 都要求把规则下到“源端口”。真正的规则 owner、switch manager port
和 domain 约束必须查看对应 PMD 文档。

> [!warning] 示例不是通用端口号
> `ethdev_port_id` 是本次 DPDK 进程枚举出的 port ID，不是 VF index、PCI function
> 或 Linux interface index。每次启动后都应重新发现映射。

### 4.6 同步 Flow API 与异步 Flow API

传统 `rte_flow_validate()` / `rte_flow_create()` 适合：

- PoC 与低频规则；
- 启动期静态配置；
- 规则失败时需要立即返回具体错误。

当系统需要高频安装大量短流时，同步创建可能让控制线程阻塞。DPDK 的 template/async
flow API 将处理拆为：

```text
configure:
  flow configure
  → pattern template
  → actions template
  → template table
  → async queue

runtime:
  enqueue create/destroy/update
  → push
  → pull completion
```

异步并不等于“调用成功就是硬件成功”。应用必须消费 completion，维护
`PENDING → ACTIVE/FAILED` 状态，并给 pending queue 设置上限。否则硬件变慢或队列堵塞时，
控制面会继续接收新连接，最终在内存中形成无界积压。

---

## 5. 什么适合卸载，什么不适合

### 5.1 适合硬件流水线

- L2/L3/L4 classification；
- VLAN、VXLAN、GENEVE、GRE 等固定格式 tunnel；
- header rewrite；
- stateless ACL；
- meter、counter、sample；
- endpoint steering；
- 大量稳定 elephant flows。

### 5.2 更适合软件或协同处理

- 复杂连接状态机；
- 需要深度重组的应用层处理；
- 不规则或快速变化的协议；
- 大量短命 mouse flows；
- 异常、分片、邻居解析和控制报文；
- 硬件不支持的 action 组合。

“Firewall → LB → DPI → IPsec 全塞进一条 P4 pipeline”通常是不现实的表达：

- DPI 可能需要跨包重组和 regex 引擎；
- IPsec 涉及 SA、序列号、抗重放和密钥；
- LB 可能维护连接状态；
- 不同能力可能位于不同硬件引擎或软件进程。

更准确的架构是：

```text
E-Switch pipeline
  classification / steering / simple actions
          │
          ├─ hardware accelerator
          ├─ DPU CPU service
          ├─ host software slow path
          └─ wire / VF / SF
```

---

## 6. DPDK 在 SmartNIC 系统中的三个位置

### 6.1 Host DPDK

运行在服务器 CPU 上：

- 管理 PF/VF/SF representor；
- 用 `rte_flow` 编程 E-Switch；
- 处理 miss 和 exception；
- 与 OVS、VPP 或自研控制面集成。

适合不需要独立信任域，或者 SmartNIC 仅作为硬件 pipeline 的场景。

### 6.2 DPU embedded CPU 上的 DPDK

运行在 DPU 的 Arm/通用核：

- 基础设施控制面不依赖 host；
- host 无法轻易绕过策略；
- 可处理 E-Switch miss 和设备管理；
- 能与 storage/security SDK 协同。

但 embedded CPU 核数和内存带宽有限，不应把所有 line-rate 包都送到 DPU CPU。

### 6.3 Host + DPU 分层

```text
host:
  tenant workload / application dataplane

DPU CPU:
  control agent / slow path / telemetry / lifecycle

hardware pipeline:
  stable high-rate forwarding
```

这是最常见也最合理的职责划分。DPU CPU 的价值是控制与隔离，不是替代 ASIC pipeline。

---

## 7. 主流平台：按架构能力而非营销名称比较

下面只列可从厂商公开资料确认的高层能力。实际功能取决于 SKU、许可、固件和 SDK。

| 平台                  | 通用计算                     | 网络能力             | 典型编程面                            |
| --------------------- | ---------------------------- | -------------------- | ------------------------------------- |
| NVIDIA BlueField-3    | 16 个 Arm 核，独立 DDR 与 OS | 最高 400 Gb/s        | DPDK、OVS、DOCA Flow、RDMA/DOCA       |
| Intel IPU E2100       | 16 个 Arm Neoverse N1 核     | 200 GbE              | IPDK、P4 pipeline、DPDK/SPDK 生态     |
| AMD Pensando DSC2-200 | Elba P4-programmable DPU     | 2×40/100/200G 等组合 | Pensando SSDK、gRPC/custom management |
| FPGA SmartNIC         | FPGA fabric，部分型号带 CPU  | 取决于板卡           | RTL/HLS/P4/厂商框架                   |

### 7.1 对原文产品描述的纠正

- BlueField-3 是 **16 个 Arm 核**，不是 8 个 A78。
- Intel E810 是 Ethernet controller 系列，不等于 IPU；E2100 才是 200GbE IPU 产品。
- E2100 使用 Arm Neoverse N1 compute complex，不是“4 个 A72”。
- Pensando 官方产品是 DSC/Elba 等命名，本文未找到可信的一手资料支持
  “Capsule/Cape 是 Pensando 正式 SmartNIC 架构”的说法，因此删除。
- Intel Tofino 是 P4-programmable Ethernet **switch ASIC/IFP**，不是典型 PCIe SmartNIC。
- Tofino 的交换容量不能直接与单端口 NIC 带宽放在同一表中比较。

### 7.2 Tofino 为什么仍值得了解

Tofino 展示了 P4/PISA 在交换芯片中的价值：

- 固定时钟下执行受约束的 match-action pipeline；
- 线速处理大量端口；
- 将 telemetry、tunnel 和 ACL 映射到硬件 stage。

但它和 DPDK 的关系更多是：

- DPDK host/DPU 与 Tofino switch 互联；
- 使用类似 P4Runtime 的控制模型；
- 软件 pipeline 与硬件 pipeline 做功能分层。

不能用 DPDK PMD API 直接把 Tofino 当普通 NIC 编程。

---

## 8. BlueField：模式决定信任边界

BlueField 常见模式包括：

- **DPU/embedded mode**：embedded Arm 侧拥有 NIC 资源和 E-Switch 控制权；
- **zero-trust DPU mode**：进一步限制 host 对设备管理能力；
- **NIC mode**：从 host 视角更接近普通适配器。

模式改变的不是一个性能开关，而是：

- 谁负责加载驱动和固件；
- 谁能创建/修改 E-Switch 规则；
- host 是否能 reset 或重新配置设备；
- 网络在 embedded 软件未启动时是否可用；
- 运维和恢复由 host 还是 DPU/BMC 执行。

### 8.1 DOCA Flow 与 DPDK 的关系

DOCA Flow 是 NVIDIA 的硬件加速 flow/pipeline API，可以在 host 或 BlueField 上运行。
它假设开发者熟悉 DPDK，但不是 `rte_flow` 的简单别名。

当前 DOCA Flow switch mode 有自己的端口管理模型：

- 通过 `doca_dev` / `doca_dev_rep` 关联物理功能和 representor；
- 由 switch manager port 统一管理 pipes；
- VF/SF representor 不应再用普通 DPDK ethdev 初始化流程重复配置；
- miss 流量可以送到 RSS software path。

因此不能把一段旧版 `doca_flow_rule_create()` 伪代码当成稳定 API 示例。
使用 DOCA 时必须匹配具体 DOCA release 的 programming guide 和 sample。

---

## 9. 设备绑定与驱动模型

原文建议把所有 SmartNIC 都绑定到 `vfio-pci`，这不正确。

### 9.1 Bifurcated driver

mlx5 等 PMD 使用 bifurcated driver 模型：

- 内核驱动继续管理设备、RDMA 和控制资源；
- DPDK PMD 通过 rdma-core/devx 等接口使用用户态数据路径；
- 通常不应把设备从 `mlx5_core`/内核 RDMA 栈解绑到 `vfio-pci`。

### 9.2 VFIO 模型

其他 PMD 或 VF 可能使用 `vfio-pci`：

```bash
dpdk-devbind.py --status
dpdk-devbind.py -b vfio-pci 0000:3b:00.1
```

实际绑定方式必须查对应 PMD 文档。错误解绑可能导致：

- representor 消失；
- devlink/switchdev 无法管理；
- RDMA 资源不可用；
- 固件和健康管理能力丢失；
- host 与 DPU 控制权冲突。

---

## 10. 资源不是无限的

硬件 flow 可能消耗：

- exact-match SRAM；
- TCAM；
- counter/meter；
- modify-header object；
- tunnel encap/decap object；
- connection tracking / ASO object；
- queue、hairpin 与 metadata register。

同一条高层规则可能展开为多个硬件对象。容量还取决于 key/action 组合，
不能只问“最多支持多少条 flow”。

### 10.1 资源管理策略

```text
admission:
  validate capability and reserve objects

installation:
  create shared action → create flow → publish state

runtime:
  count hits → age cold flows → detect pressure

eviction:
  move cold/unsupported flows back to software

recovery:
  replay desired state after reset
```

可以使用 AGE action 和 aged-flow API 回收冷流，但要考虑：

- age notification 是否可靠消费；
- flow 被 aged 后是否仍需控制面确认；
- counter 与 age action 是否共享；
- 删除顺序是否会留下间接 action；
- 设备 stop/reset 后对象是否保留。

### 10.2 不要只测“最大规则数”

容量测试至少要形成二维矩阵：

| 变量          | 示例                                               |
| ------------- | -------------------------------------------------- |
| match 宽度    | L2、IPv4 5-tuple、IPv6 5-tuple、inner+outer tunnel |
| action 复杂度 | count、rewrite、meter、encap、sample、CT           |
| 表结构        | exact match、wildcard、多个 group/jump             |
| 对象共享      | 每 flow 独占或共享 counter/encap/action            |
| 更新模式      | 单条同步、批量、async/template                     |

同一设备可能容纳几十万条简单 exact-match，却只能容纳少得多的
IPv6+tunnel+meter+counter 组合。PoC 应输出：

```text
rule profile
successful rule count
create/delete rules per second
p50/p99 installation latency
hardware table/object usage
first failure type
fallback packet loss and reorder
```

### 10.3 设置资源水位和准入控制

不要等到 PMD 返回 `ENOSPC` 才回退。建议使用：

```text
0% ───────── 70% ─────── 85% ─────── 95% ───── 100%
    normal      compact     reject new    emergency
                cold flow   offload       software-only
```

- **低水位**：正常安装；
- **预警水位**：主动 aging、合并 wildcard、共享 action；
- **高水位**：新 mouse flow 只走软件，保留资源给 elephant flow；
- **紧急水位**：停止非必要统计对象，保护基础连通和安全规则。

具体阈值需要根据硬件、业务峰值和恢复速度压测，不能照抄百分比。

---

## 11. 一致性、重启与故障恢复

SmartNIC 引入了第二套软件和硬件状态：

```text
orchestrator desired state
OVS/VPP/application state
DPDK rte_flow handles
PMD/firmware objects
E-Switch actual state
VF/guest observed connectivity
```

任何一层重启都可能产生漂移。

### 11.1 不要把 `struct rte_flow *` 当成持久状态

flow handle 是 PMD opaque pointer，只在当前进程/设备生命周期内有效。
持久化的应是可重建的 intent：

```text
flow_id
match
actions
priority/group
endpoint identity
generation
owner
desired status
```

进程或设备恢复后重新进行：

```text
discover ports
  → map representors
  → query capabilities
  → recreate shared objects
  → replay flows
  → verify counters/connectivity
```

### 11.2 规则更新要避免中间黑洞

更新 tunnel、nexthop 或 service chain 时，推荐顺序：

1. 创建新的 shared action/encap/nexthop；
2. 创建指向新对象的规则；
3. 原子切换入口或提高新规则优先级；
4. 等待在途包排空；
5. 删除旧规则和旧对象。

不同 PMD 对 atomic update、indirect action update 和 async flow API 的支持不同，
需要 capability 驱动。

---

## 12. 安全边界

DPU 并不会自动让系统安全。它只是提供了建立独立信任域的机会。

需要明确：

- secure boot 与固件签名由谁验证；
- host 能否修改 DPU 配置；
- BMC/管理网络如何认证；
- flow control API 是否加密并鉴权；
- tenant 是否能伪造 metadata；
- DMA/IOMMU 是否限制到授权内存；
- VF/SF reset 是否影响其他租户；
- key 是否进入 host、DPU 内存或硬件 keystore；
- DPU OS 漏洞如何升级与回滚。

### 12.1 Fail-open 还是 fail-closed

DPU agent、控制器或 embedded OS 失效时，流量策略必须预先定义：

| 策略            | 行为               | 风险             |
| --------------- | ------------------ | ---------------- |
| fail-open       | 保持或恢复基础连通 | 可能绕过安全策略 |
| fail-closed     | 阻断未确认流量     | 可能扩大故障     |
| last-known-good | 保留已验证硬件状态 | 状态可能逐渐过期 |

网络、安全和存储功能可能需要不同策略，不能只设置一个全局答案。

---

## 13. 可观测性：证明流量在哪里处理

至少建立三层指标：

### 13.1 软件层

- representor RX/TX；
- slow-path packets/bytes；
- miss reason；
- flow install success/failure/latency；
- pending packet 与队列长度；
- software fallback；
- lcore cycles 与丢包。

### 13.2 硬件层

- per-flow/per-action counter；
- hardware table usage；
- aged/evicted flow；
- meter/drop；
- tunnel/modify object 使用量；
- E-Switch port statistics；
- firmware health 与 reset。

### 13.3 业务层

- 连接建立成功率；
- p50/p99/p99.9 latency；
- packet reorder；
- VM/VF connectivity；
- rule convergence time；
- upgrade/restart interruption。

> [!warning] 统计必须有权威来源
> 软件 flow 数、硬件 flow 数和控制器 desired flow 数可能不同。界面不能把
> “下发成功”直接当成“硬件命中”，也不能用 representor 端口 up/down 推断业务可达。

### 13.4 常见现象与定位顺序

| 现象                        | 优先检查                                                               |
| --------------------------- | ---------------------------------------------------------------------- |
| flow create 成功但 CPU 不降 | counter 是否增长、规则是否进入 transfer domain、是否仍有 mirror/sample |
| VF 能发不能收               | 反向规则、uplink ingress、邻居/ARP/ND、represented port 方向           |
| 小流量正常，高并发丢包      | miss queue、pending flow、shared RX queue、flow install latency        |
| 加 tunnel 后规则失败        | encap/decap object、outer/inner pattern、action 组合、group 顺序       |
| 重启后偶发黑洞              | representor 映射变化、旧 handle、规则 replay 顺序、默认 miss 策略      |
| 规则数未满却 ENOSPC         | counter/meter/modify/encap 等辅助对象先耗尽                            |
| 删除规则后仍走硬件          | shared action 引用、重复规则、TC/OVS 与 DPDK 多控制面冲突              |

定位顺序建议固定为：

```text
endpoint/link
  → switch domain and representor mapping
  → software baseline
  → rule validate/create result
  → hardware counter
  → miss/exception path
  → table and auxiliary object usage
  → firmware health/reset history
```

固定顺序的价值是避免一看到丢包就调大 RX descriptor，或者一看到规则成功就认定
硬件没有问题。

---

## 14. 一套可执行的 SmartNIC PoC

### 14.1 阶段一：拓扑与身份

记录：

```text
PCI BDF / PF / VF / SF
DPDK port_id
switch domain_id / switch port_id
Linux netdev / representor
NUMA node
firmware / PMD / SDK version
```

验证每个 endpoint 的流量方向，避免把 representor 与 represented VF 混淆。

常用的发现命令包括：

```bash
lspci -nn
devlink dev show
devlink dev eswitch show pci/0000:08:00.0
ip -d link show
ethtool -i <representor>
dpdk-devbind.py --status
```

进入 testpmd 后至少记录：

```text
show port info all
show port stats all
flow list <port_id>
```

### 14.2 阶段二：软件基线

- 不安装 hardware flow；
- 所有目标流量经过 representor slow path；
- 测量吞吐、延迟、CPU 和丢包；
- 验证 policy/route/conntrack 正确。

### 14.3 阶段三：最小硬件规则

从最简单的端口 steering 开始：

```text
physical port → VF0
VF0 → physical port
```

然后逐步加入：

1. exact 5-tuple；
2. counter；
3. VLAN push/pop；
4. VXLAN encap/decap；
5. meter/sample；
6. aging；
7. shared/indirect action。

每一步都验证硬件 counter、slow-path 下降和删除后的回退。

建议把每一步结果记录为统一表格：

| 阶段          | 吞吐 | p99 延迟 | host CPU | DPU CPU | slow path PPS | HW counter |
| ------------- | ---- | -------- | -------- | ------- | ------------- | ---------- |
| 软件基线      |      |          |          |         |               |            |
| 端口 steering |      |          |          |         |               |            |
| 5-tuple       |      |          |          |         |               |            |
| tunnel        |      |          |          |         |               |            |
| 资源高水位    |      |          |          |         |               |            |

### 14.4 阶段四：容量与失败

测试：

- table/object 容量；
- flow 创建速率；
- 10K/100K 规则下 lookup 与控制延迟；
- 规则创建失败；
- firmware reset；
- DPU agent restart；
- representor/VF reset；
- uplink flap；
- controller disconnect；
- cold-flow aging；
- primary hardware 与 software fallback 乱序。

### 14.5 阶段五：升级

验证：

- 新旧 DPU 软件并行；
- desired state replay；
- flow counter 连续性；
- fail-open/fail-closed 行为；
- rollback；
- host 与 DPU 版本兼容。

---

## 15. 总结

SmartNIC/DPU 数据面可以浓缩为：

```text
endpoint:
  PF / VF / SF / physical port

software representation:
  representor + switch domain

hardware policy:
  rte_flow / DOCA Flow / P4 target

runtime:
  miss → software decision → hardware rule → age/recover
```

DPDK 在这里不只是收发包框架，还承担了：

- 枚举和管理 representor；
- 描述硬件 flow；
- 处理 miss 与 fallback；
- 连接 E-Switch、软件状态和控制面；
- 验证规则是否真正进入快路径。

因此，SmartNIC 项目最重要的问题不是“这张卡有多少 Arm 核”，而是：

> **端点如何表示，状态由谁拥有，硬件失败后流量回到哪里，系统如何证明实际路径？**

---

## 参考资料

### DPDK 与 Linux

- [DPDK Switch Representation](https://doc.dpdk.org/guides-26.03/prog_guide/ethdev/switch_representation.html)
- [DPDK Generic Flow API](https://doc.dpdk.org/guides-26.03/prog_guide/ethdev/flow_offload.html)
- [Linux Network Function Representors](https://docs.kernel.org/networking/representors.html)
- [Linux devlink E-Switch attributes](https://docs.kernel.org/networking/devlink/devlink-eswitch-attr.html)
- [Open vSwitch TC hardware offload](https://docs.openvswitch.org/en/latest/howto/tc-offload/)

### 产品与 SDK

- [NVIDIA BlueField-3 specifications](https://docs.nvidia.com/networking/display/BlueField3DPU/Specifications)
- [NVIDIA DOCA Flow](https://docs.nvidia.com/doca/sdk/doca-flow/index.html)
- [Intel IPU E2100](https://www.intel.com/content/www/us/en/products/details/network-io/ipu/adapter-e2100.html)
- [AMD Pensando DSC2-200 product brief](https://www.amd.com/content/dam/amd/en/documents/pensando-technical-docs/product-briefs/pensando-dsc-200-product-brief.pdf)
- [Intel Tofino Intelligent Fabric Processors](https://www.intel.com/content/www/us/en/products/details/network-io/programmable-ethernet-switch.html)
