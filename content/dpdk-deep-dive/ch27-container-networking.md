---
title: "DPDK 深度探索 ch27：容器网络"
date: 2026-04-10 09:00:00
tags: [dpdk, container, docker, kubernetes, cni, vswitch, ovs-dpdk, polkit]
description: "深入解析 DPDK 容器网络：DOCKER/CNI、VSwitch、OVS-DPDK、Multus、Pod 网络与性能"
---

# DPDK 深度探索 ch27：容器网络

> [!abstract] 核心要点
> 容器网络需要高性能数据平面。本章深入解析 DPDK 在容器环境中的应用：OVS-DPDK、VSwitch、CNI 插件与 Kubernetes 网络。

## 1. 容器网络概述

这一章讨论的不是普通 Web Pod 的网络，而是 **CNF（Cloud-native Network
Function，云原生网络功能）** 的网络。

商业上，它对应的是把原来运行在专用硬件或 VM 里的网络设备，搬到 Kubernetes
Pod 里运行：

| 传统形态     | VM/NFV 形态          | 容器/CNF 形态          |
| ------------ | -------------------- | ---------------------- |
| 硬件防火墙   | VM 防火墙 VNF        | 防火墙 Pod             |
| 硬件负载均衡 | VM 负载均衡 VNF      | LB / Gateway Pod       |
| EPC/5GC 网元 | VM UPF / BNG / CGNAT | UPF / BNG / CGNAT Pod  |
| 硬件路由器   | VM Router / vBNG     | VPP / FRR / Router Pod |

普通 Kubernetes 网络的目标是“让业务 Pod 能通信”。DPDK 容器网络的目标是：

```text
让一个 Pod 像网络设备一样高速收发包。
```

所以这类 Pod 通常不是通过普通 socket 收发业务流量，而是容器里的 DPDK/VPP/UPF
进程直接收发 packet。

### 1.1 容器网络模型

```
┌─────────────────────────────────────────────────────────────┐
│                    容器网络模型                              │
│                                                              │
│  Pod / Container                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  eth0 ←→ veth pair ←→ host eth0 ←→ physical NIC    │  │
│  │                     ↑                                 │  │
│  │              Linux Bridge / OVS                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  问题：                                                     │
│  - veth pair 需要 kernel 处理                              │
│  - Bridge 学习/转发需要 CPU                               │
│  - 无法利用 DPDK 加速                                      │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 DPDK 容器网络优势

| 方案             | 吞吐量      | 延迟   | CPU 开销 |
| ---------------- | ----------- | ------ | -------- |
| **Linux Bridge** | ~2-3 Gbps   | ~100μs | 高       |
| **OVS (kernel)** | ~3-4 Gbps   | ~80μs  | 高       |
| **OVS-DPDK**     | ~10-15 Gbps | ~20μs  | 低       |
| **VPP**          | ~10-15 Gbps | ~15μs  | 低       |

### 1.3 先区分控制面和数据面

容器网络里最容易混淆的是：Kubernetes、CNI、Multus、Device Plugin 主要在
**创建 Pod 时配置网络**，它们不在每个包的数据路径上。

```
控制面：创建和配置网络

Kubernetes API
  -> kubelet
  -> container runtime
  -> CNI / Multus
  -> 创建 veth / vhost-user socket / 分配 SR-IOV VF
  -> 给 Pod 注入设备、IP、大页、PCI 资源

数据面：真正处理每一个包

Packet
  -> Pod 内 App / DPDK / VPP
  -> veth / vhost-user / SR-IOV VF
  -> Host vSwitch / NIC
```

也就是说：

| 模块                   | 属于哪一面 | 作用                                   |
| ---------------------- | ---------- | -------------------------------------- |
| Kubernetes API/kubelet | 控制面     | 调度 Pod，调用 CNI                     |
| CNI                    | 控制面     | 创建接口、分配 IP、连接网络            |
| Multus                 | 控制面     | 给一个 Pod 挂多个网络                  |
| Device Plugin          | 控制面     | 把 VF、DPDK 设备、大页等资源暴露给 K8s |
| veth / OVS / OVS-DPDK  | 数据面     | 处理包转发                             |
| DPDK PMD / VPP / UPF   | 数据面     | 在用户态高速收发包                     |

### 1.4 三种典型流量路径

#### 路径 A：普通 Kubernetes Pod

这是最常见的业务容器路径。它和 DPDK 没有直接关系。

```
┌─────────────────────────────────────────────────────────────────────┐
│ Pod                                                                 │
│                                                                     │
│  App                                                                │
│   │ socket                                                          │
│   ▼                                                                 │
│  Pod Linux network stack                                            │
│   │                                                                 │
│   ▼                                                                 │
│  eth0                                                               │
└───┬─────────────────────────────────────────────────────────────────┘
    │ veth pair
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Host kernel                                                         │
│                                                                     │
│  host-side veth                                                     │
│   │                                                                 │
│   ▼                                                                 │
│  Linux bridge / OVS kernel / CNI datapath                           │
│   │                                                                 │
│   ▼                                                                 │
│  Host NIC driver                                                    │
└───┬─────────────────────────────────────────────────────────────────┘
    │
    ▼
Physical NIC
```

这个路径的特点：

- 每个包都会进入 Pod/Host kernel 网络栈。
- 适合普通微服务、数据库、Web 服务。
- 不适合 5G UPF、防火墙、网关这类高 PPS 网络功能。

#### 路径 B：Pod 内 DPDK/VPP + OVS-DPDK vhost-user

这是 DPDK 容器网络里最接近 vhost-user 的路径。注意这里的业务包不走 Pod 的
`eth0`，而是走容器内 DPDK/VPP 创建的 vhost-user 接口。

```
┌─────────────────────────────────────────────────────────────────────┐
│ Pod / Container                                                     │
│                                                                     │
│  VPP / DPDK Network Function                                        │
│   │                                                                 │
│   │ userspace packet                                                │
│   ▼                                                                 │
│  vhost-user interface                                               │
│  - virtqueue / descriptor                                           │
│  - shared memory                                                    │
│  - kick/call eventfd                                                │
└───┬─────────────────────────────────────────────────────────────────┘
    │ Unix socket 只传控制信息和 fd，packet 通过共享内存交换
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│ Host userspace                                                      │
│                                                                     │
│  OVS-DPDK                                                           │
│   │                                                                 │
│   ├─ dpdkvhostuser / dpdkvhostuserclient port                       │
│   │    - 读取/写入 vhost-user virtqueue                             │
│   │                                                                 │
│   ├─ OpenFlow / datapath lookup                                     │
│   │    - 查流表，决定转发到哪里                                     │
│   │                                                                 │
│   └─ dpdk physical port                                             │
│        - DPDK PMD 驱动物理网卡                                      │
└───┬─────────────────────────────────────────────────────────────────┘
    │
    ▼
Physical NIC
```

这个路径的模块顺序是：

```text
Container DPDK/VPP
  -> vhost-user virtqueue
  -> OVS-DPDK vhost port
  -> OVS-DPDK flow table
  -> OVS-DPDK dpdk physical port
  -> NIC
```

它适合：

- 容器化 VPP Router
- 容器化防火墙
- 容器化 LB/Gateway
- 需要经过 Host vSwitch 做策略、镜像、ACL、转发编排的 CNF

#### 路径 C：Pod 内 DPDK + SR-IOV VF

SR-IOV 是更直接的路径：把物理网卡切出来的 VF 直接分给 Pod。

```
┌─────────────────────────────────────────────────────────────────────┐
│ Pod / Container                                                     │
│                                                                     │
│  DPDK App / UPF / Firewall                                          │
│   │                                                                 │
│   ▼                                                                 │
│  DPDK PMD                                                           │
│   │                                                                 │
│   ▼                                                                 │
│  VF PCI device inside Pod                                           │
└───┬─────────────────────────────────────────────────────────────────┘
    │ PCI passthrough / device plugin
    ▼
Physical NIC VF
    │
    ▼
NIC hardware switch / wire
```

这个路径的模块顺序是：

```text
Container DPDK app
  -> DPDK PMD
  -> SR-IOV VF
  -> NIC hardware
```

它的优点是延迟低、吞吐高；缺点是 Host vSwitch 很难再完整接管这条流量路径，
安全组、ACL、镜像、迁移和编排会更复杂。

### 1.5 和 veth/netkit fast redirect 的关系

前面三条路径容易让人产生一个问题：如果普通容器网络已经可以通过 eBPF redirect
加速，为什么还需要 DPDK 容器网络？

这里要区分两个目标：

```text
veth/netkit fast redirect:
  把通用 Kubernetes Pod 网络做快

DPDK/vhost-user/SR-IOV:
  让 Pod 变成专用网络设备
```

现代 veth 已经不是只能走完整 Host 网络栈的老路径。通过 TC BPF 和
`bpf_redirect_peer()`，veth 可以把同节点 Pod-to-Pod 路径缩短：

```text
Pod A App
  -> socket
  -> Pod A kernel
  -> veth ingress BPF
  -> bpf_redirect_peer()
  -> Pod B ingress
  -> Pod B kernel
  -> Pod B App
```

netkit 则进一步把容器虚拟网卡做成 BPF-first 模型：

```text
Pod App
  -> socket
  -> Pod kernel
  -> netkit device
  -> BPF policy / redirect
  -> peer Pod / Host / NIC
```

这两类方案仍然保留普通 Linux socket 和 Kubernetes 网络语义。普通业务应用不用改代码，
仍然可以使用 Service、NetworkPolicy、可观测性和常规运维工具。

DPDK 容器网络则不同：

```text
Container DPDK/VPP/UPF
  -> mbuf / userspace ring
  -> vhost-user / memif / SR-IOV VF
  -> OVS-DPDK / VPP / NIC
```

它绕过了普通 socket 和内核 TCP/IP 栈，要求应用本身就是 packet processor。

| 维度            | veth/netkit fast redirect          | DPDK/vhost-user/SR-IOV           |
| --------------- | ---------------------------------- | -------------------------------- |
| 目标            | 加速通用容器网络                   | 构建专用高性能网络功能           |
| 应用模型        | 普通 socket 应用                   | DPDK/VPP/UPF 等 packet processor |
| 数据结构        | `skb` + Linux 网络栈               | `mbuf` / userspace ring / VF     |
| 转发位置        | 内核 eBPF hook                     | 用户态轮询或 NIC 硬件            |
| Kubernetes 语义 | 保留较完整                         | 需要额外集成和资源编排           |
| 典型场景        | 微服务、Service、同节点 Pod-to-Pod | UPF、防火墙、LB、NAT、DDoS       |

所以：

```text
普通业务 Pod:
  优先考虑 Cilium eBPF、veth fast redirect、netkit

网络功能 Pod:
  考虑 DPDK、VPP、vhost-user、memif、SR-IOV
```

> [!tip] 延伸阅读
> 关于 veth、netkit、`bpf_redirect_peer()` 的详细路径对比，可以看：
> [[netkit-container-networking|eBPF 深入理解：netkit、veth 与容器网络加速]]

## 2. OVS-DPDK

### 2.1 OVS-DPDK 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    OVS-DPDK 架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Open vSwitch (DPDK)                      │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │  Bridge  │  │  Port    │  │  Flow    │          │  │
│  │  │  Table   │  │  Table   │  │  Table   │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK (PMD + vhost-user)                  │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │  netdev  │  │  netdev │  │  netdev │          │  │
│  │  │  (dpdk)  │  │(vhost)  │  │(tap)    │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 OVS-DPDK 安装

```bash
# 安装 OVS-DPDK
apt-get install openvswitch-switch-dpdk

# 查看 DPDK 设备
ovs-dpdk-listen -c 0-3 -m 1024

# 查看大页
cat /proc/meminfo | grep Huge
# HugePages_Total:    512
# Hugepagesize:       2048 kB
```

### 2.3 OVS-DPDK 配置

```bash
# 初始化 OVS
ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl set Open_vSwitch . other_config:dpdk-lcore-mask=0xF
ovs-vsctl set Open_vSwitch . other_config:dpdk-huge-dir=/mnt/huge
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0xF

# 创建 Bridge
ovs-vsctl add-br br0 -- set Bridge br0 datapath_type=netdev

# 添加 DPDK 端口
ovs-vsctl add-port br0 dpdk0 -- set Interface dpdk0 \
    type=dpdk options:dpdk-devargs=0000:3d:00.0

# 查看端口
ovs-vsctl show

# 示例：
# Bridge br0
#     datapath_type: netdev
#     Port br0
#         Interface br0
#     Port "dpdk0"
#         Interface "dpdk0"
#             type: dpdk
```

## 3. Vhost-user Container 连接

### 3.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│              Vhost-user 容器连接：数据面路径                │
│                                                              │
│  Container / Pod                                              │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  VPP / DPDK App                                      │    │
│  │      │                                                │    │
│  │      ▼                                                │    │
│  │  vhost-user interface                                │    │
│  │  - vring descriptor                                  │    │
│  │  - avail / used ring                                 │    │
│  │  - packet buffer                                     │    │
│  └──────┬───────────────────────────────────────────────┘    │
│         │ Unix socket 建连；packet 通过共享内存交换           │
│         ▼                                                     │
│  Host userspace                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │  OVS-DPDK                                            │    │
│  │      │                                                │    │
│  │      ├─ vhost-user port                              │    │
│  │      │   读取 Container 提交的 descriptor             │    │
│  │      │                                                │    │
│  │      ├─ flow table lookup                            │    │
│  │      │   决定转发到另一个 Pod、VM、tunnel 或物理口     │    │
│  │      │                                                │    │
│  │      └─ dpdk physical port                           │    │
│  │          调用 NIC PMD 发包                            │    │
│  └──────┬───────────────────────────────────────────────┘    │
│         ▼                                                     │
│  Physical NIC                                                 │
└─────────────────────────────────────────────────────────────┘
```

关键点：

- `vhost-user socket` 不是传每一个包的管道，主要用于建连、协商、传递 fd。
- 真正的 packet 数据在共享内存中的 buffer 里。
- `descriptor ring` 告诉对方：“这个 packet buffer 在哪里、长度是多少、方向是什么”。
- OVS-DPDK 的 vhost-user port 收到包后，还要经过 OVS flow table，才能决定发往哪个端口。

所以 vhost-user 容器场景里，流量不是：

```text
Pod eth0 -> veth -> bridge
```

而更像：

```text
VPP/DPDK in Pod
  -> vhost-user descriptor
  -> OVS-DPDK vhost port
  -> OVS-DPDK flow table
  -> another vhost port / tunnel / physical DPDK port
```

### 3.2 容器网络配置

先强调一点：下面的 `ovs-vsctl add-port` **只是在 OVS-DPDK 里创建端口**，它不负责
创建容器，也不负责在容器里创建 Linux `eth0/net1`。

完整流程应该分成三段：

```text
1. Kubernetes / container runtime 创建 Pod
   - 默认 CNI 创建 eth0
   - Multus/secondary CNI 创建 net1/net2，或准备 socket/设备资源

2. CNF 容器里的 VPP/DPDK 进程创建 vhost-user socket/interface
   - 例如 /var/run/vpp/c1.sock
   - 这是 VPP/DPDK 进程里的用户态接口，不是 Linux veth

3. OVS-DPDK 创建 dpdkvhostuserclient 端口
   - 连接到 /var/run/vpp/c1.sock
   - 连接成功后，这个端口进入 OVS-DPDK br0 参与转发
```

所以真实时序更像：

```text
Kubelet
  -> container runtime 创建 Pod sandbox
  -> primary CNI 创建 eth0
  -> Multus 调用 secondary CNI / 注入资源
  -> CNF 容器启动 VPP/DPDK
  -> VPP/DPDK 创建 vhost-user socket
  -> OVS-DPDK add-port 连接 socket
  -> OVS-DPDK br0 开始把这个容器当成一个交换机端口
```

执行 `ovs-vsctl add-port` 前，OVS-DPDK 只有一个 bridge，还没有能连接 VPP/DPDK
容器的端口：

```text
Before:

VPP / DPDK Container
  vhost-user socket: /var/run/vpp/c1.sock

OVS-DPDK
  br0
    dpdk0 / physical port / other ports
    no vhost-user port for c1.sock
```

执行 `ovs-vsctl add-port` 以后，OVS 的 `br0` 里会多一个 DPDK vhost-user netdev。这个
netdev 不是 Linux `veth`，而是 OVS-DPDK 数据面里的一个用户态端口：

```text
After:

VPP / DPDK Container
  vhost-user socket: /var/run/vpp/c1.sock
        ▲
        │ Unix socket 建连、协商 feature、传递 vring/eventfd
        │ packet 数据通过共享内存中的 vring/buffer 交换
        ▼
OVS-DPDK
  br0
    vhost-client1: dpdkvhostuserclient
    dpdk0: physical NIC port
    other ports
```

推荐模式是 `dpdkvhostuserclient`：

```bash
# OVS 作为 vhost-user client，连接到 VPP/DPDK 容器创建的 socket
ovs-vsctl add-port br0 vhost-client1 -- \
    set Interface vhost-client1 \
    type=dpdkvhostuserclient \
    options:vhost-server-path=/var/run/vpp/c1.sock \
    options:vhost-client-reconnect-interval=1000
```

这条命令做了四件事：

```text
1. 在 br0 上创建一个名为 vhost-client1 的端口
2. 把这个端口类型设为 dpdkvhostuserclient
3. 告诉 OVS-DPDK 去连接 /var/run/vpp/c1.sock
4. 如果对端还没起来，OVS-DPDK 按 reconnect interval 重试连接
```

连接成功后，OVS-DPDK 可以把 `vhost-client1` 当成普通交换机端口参与转发：

```text
VPP/DPDK container
  -> vhost-user ring
  -> OVS-DPDK vhost-client1
  -> OVS flow lookup
  -> dpdk0 / another vhost port / tunnel
```

老的服务端模式是 `dpdkvhostuser`：

```bash
# OVS 作为 vhost-user server，由 OVS 创建 socket
ovs-vsctl add-port br0 vhost-server1 -- \
    set Interface vhost-server1 \
    type=dpdkvhostuser
```

这种模式下，socket 通常由 OVS 按 `other_config:vhost-sock-dir` 和 interface name
创建，例如：

```text
<vhost-sock-dir>/vhost-server1
```

对端 VPP/DPDK 进程再作为 client 去连接这个 socket。现代 OVS-DPDK 部署一般更推荐
`dpdkvhostuserclient`，因为 QEMU/VPP/DPDK 应用重启时，OVS 可以持续重连，运维上
更稳定。

如果不用 Kubernetes，只用本机容器演示，顺序大概是：

```bash
# 1. 启动 VPP/DPDK 容器，并把 socket 目录和 hugepage 目录挂进去
docker run -d --name vpp-cnf \
    --privileged \
    -v /dev/hugepages:/dev/hugepages \
    -v /var/run/vpp:/var/run/vpp \
    fdio/vpp

# 2. 在 VPP 里创建 vhost-user interface/socket
#    具体命令可能随 VPP 版本变化，这里表达的是动作：
docker exec -it vpp-cnf vppctl create vhost-user socket /var/run/vpp/c1.sock
docker exec -it vpp-cnf vppctl set interface state VirtualEthernet0/0/0 up

# 3. 在 Host OVS-DPDK 上创建 client 端口连接它
ovs-vsctl add-port br0 vhost-client1 -- \
    set Interface vhost-client1 \
    type=dpdkvhostuserclient \
    options:vhost-server-path=/var/run/vpp/c1.sock \
    options:vhost-client-reconnect-interval=1000
```

如果在 Kubernetes 里，`docker run` 这一步会被 Pod spec 替代，socket 目录、
hugepage、VF/DPDK 设备会通过 `volumeMounts`、`resources`、`securityContext`、
Multus annotation 和 device plugin 注入。

查看端口状态：

```bash
# 查看 OVS 配置
ovs-vsctl show

# 查看端口状态
ovs-ofctl show br0
```

### 3.3 三类接口不要混在一起

VPP 容器网络里最容易混淆的是：同一个“连接”会同时出现三个不同层面的对象。

| 对象                     | 在哪里                | 谁创建               | 作用                                                |
| ------------------------ | --------------------- | -------------------- | --------------------------------------------------- |
| Pod `eth0/net1`          | Linux container netns | CNI / Multus         | 普通 Linux 网口，用于管理流量或 secondary network   |
| VPP vhost-user interface | VPP 进程内部          | VPP CLI / VPP 配置   | VPP 的用户态收发包接口，不一定能在 `ip link` 里看到 |
| OVS `vhost-client1`      | OVS-DPDK 进程内部     | `ovs-vsctl add-port` | OVS-DPDK bridge 上的用户态端口                      |

严格按职责划分：

```text
CNI / Multus:
  负责 Pod 网络命名空间、Linux 网口、IP、路由、设备/资源注入

VPP 应用 / VPP agent / CNF 自己的启动配置:
  负责在 VPP 进程里创建 vhost-user interface

OVS CNI / Operator / Host 脚本:
  负责在 OVS-DPDK 里创建 vhost-user port
```

所以“VPP 创建接口”这一步，机制上更应该算 **应用自己的行为**，或者算
**CNF 的控制面/agent 行为**，而不是标准 CNI 行为。

工程上有些方案会把它自动化：CNI 插件或 Operator 在 Pod 创建时顺手调用 VPP API、
生成 VPP startup 配置、创建 OVS 端口。此时从用户体验看像是“CNI 做的”，但底层职责
仍然是：CNI 接线，VPP 创建自己的用户态接口，OVS 创建自己的交换机端口。

所以这里不是：

```text
ovs-vsctl add-port
  -> 在容器里创建 net1
```

而是：

```text
CNI / Multus
  -> 创建 Pod 的 Linux 网络环境和普通网口

VPP
  -> 创建 VPP 内部的 vhost-user interface/socket

OVS-DPDK
  -> 创建 OVS bridge 上的 vhost-user port，并连接 VPP socket
```

如果 CNF 是 VPP，包进入容器后也不一定经过 Linux `eth0/net1`。高性能数据面通常是：

```text
OVS-DPDK vhost-client1
  -> vhost-user shared memory / vring
  -> VPP vhost-user interface
  -> VPP graph nodes
  -> VPP 另一个接口 / NAT / firewall / router
```

这也是为什么你在容器里执行：

```bash
ip link
```

可能只看到 Linux 网口；而 VPP 的接口需要用：

```bash
vppctl show interface
vppctl show hardware
```

OVS 侧则用：

```bash
ovs-vsctl show
ovs-vsctl list Interface vhost-client1
```

一句话：

```text
Pod 网口解决“容器怎么接入 Kubernetes 网络”；
VPP vhost-user interface 解决“VPP 怎么收发包”；
OVS vhost-user port 解决“OVS-DPDK 怎么把这个 VPP 接到交换机里”。
```

### 3.4 Kubernetes 体系内和体系外的边界

这里的边界确实很模糊，因为 Kubernetes 的控制对象和真实数据面不在同一层。

Kubernetes 体系内通常是：

```text
Pod
Deployment / DaemonSet
NetworkAttachmentDefinition
Device Plugin resource
ConfigMap / Secret
CRD / Operator
Service / NetworkPolicy
```

这些对象描述的是“想要什么”：

```text
我要一个 CNF Pod
我要两个 secondary interfaces
我要一个 SR-IOV VF
我要 hugepage
我要把某个网络策略应用到这个 Pod
```

但真正转发包的对象很多不在 Kubernetes 原生模型里：

```text
OVS bridge
OVS-DPDK port
OpenFlow table
VPP interface
VPP graph node
DPDK PMD queue
vhost-user socket
SR-IOV VF hardware queue
```

这些对象才真正决定 packet 怎么走：

```text
packet
  -> VPP / OVS-DPDK / DPDK PMD / NIC
  -> flow table / graph node / hardware queue
```

所以更准确的分层是：

| 层次              | 例子                                           | 作用                        |
| ----------------- | ---------------------------------------------- | --------------------------- |
| Kubernetes 声明层 | Pod、NAD、CRD、Device Plugin resource          | 描述期望状态                |
| 集成层            | CNI、Multus、Operator、vpp-agent、ovs-operator | 把 K8s 对象翻译成数据面配置 |
| 数据面层          | OVS-DPDK、VPP、DPDK PMD、SR-IOV VF             | 真正收发和转发 packet       |

这就是为什么 OVS-DPDK 看起来“不在 K8s 体系内”，却能左右 K8s Pod 流量：

```text
Kubernetes 不直接转发包；
Kubernetes 通过 CNI/Operator 把配置下发给 OVS/VPP；
OVS/VPP/DPDK 才是实际的数据面。
```

工程上要避免的误解是：

```text
有 Kubernetes 对象
  ≠ Kubernetes 自己在转发这些包

Pod 里有 net1
  ≠ net1 后面的交换、路由、安全策略都由 Kubernetes 原生对象控制

OVS/VPP 由 Operator 创建
  ≠ OVS/VPP 的全部状态都能被 Kubernetes 自动理解
```

所以 CNF 场景里经常需要额外的同步和观测：

```text
K8s 对象状态
  -> Pod Ready / NAD / CRD status

数据面状态
  -> ovs-vsctl show
  -> ovs-ofctl dump-flows
  -> vppctl show interface
  -> vppctl show trace
  -> dpdk telemetry
  -> NIC queue counters
```

一句话：

```text
Kubernetes 管生命周期和期望状态；
CNI/Operator 管翻译；
OVS/VPP/DPDK 管真实流量。
```

### 3.5 谁规定 VPP 接口名和 OVS 端口信息

标准 CNI 只规定了插件调用模型：

```text
ADD / DEL / CHECK
container id
network namespace path
requested interface name
stdin JSON config
result: interfaces / IPs / routes
```

它不会天然知道：

```text
VPP 里应该创建哪个 vhost-user interface
socket 路径应该叫什么
OVS-DPDK 端口应该叫什么
OVS 端口应该接哪个 bridge
VPP interface 和 OVS port 如何一一对应
```

这些必须由具体实现约定。常见做法是让 `NetworkAttachmentDefinition`、CRD、Operator
或自定义 CNI 成为状态源。

一个合理的约定是：

```text
Pod UID:        8f3a...
Network name:   dataplane-net
Pod interface:  net1

生成：
  socket path:  /var/run/vhost/8f3a-net1.sock
  OVS port:     pod-8f3a-net1
  VPP tag:      pod-8f3a-net1
```

然后各组件按这个约定行动：

```text
Multus / secondary CNI:
  读取 NAD
  知道这个 Pod 需要 dataplane-net
  给 Pod 分配 net1 这个逻辑接口名
  生成 socket path / port name / metadata

VPP agent / CNF init:
  根据 socket path 创建 vhost-user interface
  给 VPP interface 打 tag，方便后续查询

OVS CNI / Operator:
  根据同一个 socket path 创建 OVS-DPDK vhost-user port
  设置 external_ids，记录 pod name / namespace / uid / interface
```

OVS 端口通常也会记录 Kubernetes 元信息，方便排障和回收：

```bash
ovs-vsctl add-port br0 pod-8f3a-net1 -- \
    set Interface pod-8f3a-net1 \
    type=dpdkvhostuserclient \
    options:vhost-server-path=/var/run/vhost/8f3a-net1.sock \
    external_ids:pod_uid=8f3a... \
    external_ids:pod_name=upf-0 \
    external_ids:pod_namespace=cnf \
    external_ids:pod_interface=net1
```

这样后续 Pod 删除时，Operator/CNI 才知道要清理：

```text
VPP interface tag: pod-8f3a-net1
OVS port:          pod-8f3a-net1
socket file:       /var/run/vhost/8f3a-net1.sock
```

注意：VPP 内部接口名不一定等于 Kubernetes 里的 `net1`。VPP 可能生成类似
`VirtualEthernet0/0/0` 的名字，所以工程上更常用 **tag / socket path / metadata**
作为稳定标识，而不是强行依赖 VPP 自动生成的接口名。

### 3.6 为什么不是 memif

不是不能用 memif。memif（memory interface）也是用户态进程之间通过共享内存交换包
的一种方式，在 VPP/FD.io 生态里很常见。

如果场景是：

```text
VPP container A
  -> memif
  -> VPP container B
```

或者：

```text
VPP
  -> memif
  -> 另一个明确支持 memif 的 DPDK/VPP 应用
```

memif 很合适，协议更轻，路径也很直接。

但在 OVS-DPDK / QEMU / virtio 混合场景里，vhost-user 更常见，原因是：

| 维度          | vhost-user                                   | memif                                          |
| ------------- | -------------------------------------------- | ---------------------------------------------- |
| 生态来源      | virtio/vhost/QEMU/OVS-DPDK                   | FD.io/VPP                                      |
| VM 兼容性     | 强，能直接接 virtio-net/vhost-user 体系      | 弱，VM virtio-net 不使用 memif                 |
| OVS-DPDK 支持 | 一等端口类型：`dpdkvhostuserclient`          | 取决于 DPDK PMD/部署方式，不如 vhost-user 通用 |
| VPP 支持      | 支持                                         | 很强，是 VPP 常用高性能接口                    |
| 协议语义      | virtqueue、virtio feature、eventfd、共享内存 | memif ring、共享内存、轻量控制协议             |
| 适合场景      | VM/CNF/OVS-DPDK 统一接入 Host vSwitch        | VPP-to-VPP 或明确支持 memif 的进程间高速连接   |

所以选型不是：

```text
vhost-user 一定比 memif 好
```

而是：

```text
如果要接 OVS-DPDK / QEMU / VM / virtio 生态:
  vhost-user 更自然

如果两端都是 VPP/FD.io 风格的数据面:
  memif 可能更简单、更轻
```

这也是为什么容器 CNF 里经常同时看到两种路径：

```text
Container VPP <-> Host OVS-DPDK:
  vhost-user

VPP <-> VPP:
  memif
```

> [!tip] 延伸阅读
> memif 的 VPP 视角可以继续看：
> [[ch19a-memif|VPP 深入探讨 ch19a：memif 内存接口]]

## 4. CNI 插件

### 4.1 CNI 概述

```
Container Network Interface (CNI):

┌─────────────────────────────────────────────────────────────┐
│                    CNI 流程                                 │
│                                                              │
│  Container Runtime → CNI Plugin → Network                  │
│                                                              │
│  ADD: 创建网络接口 + 配置 IP                               │
│  DEL: 删除网络接口                                         │
│  CHECK: 检查配置                                            │
│  VERSION: 返回版本                                          │
└─────────────────────────────────────────────────────────────┘
```

CNI 的位置要特别注意：它在 Pod 创建/删除时执行，不在每个 packet 的转发路径上。

```
Pod 创建时：

kubelet
  -> container runtime
  -> CNI ADD
  -> 创建接口 / socket / VF
  -> 配 IP / 路由 / namespace
  -> Pod started

Pod 收发包时：

packet
  -> 已经创建好的 veth / vhost-user / VF
  -> 数据面模块转发
```

所以 CNI 更像“施工队”，负责把网线、端口、IP、设备接好；真正转发包的是
Linux bridge、OVS-DPDK、VPP、SR-IOV VF 或 NIC。

### 4.2 DPDK CNI 插件

```go
// dpdkcni/main.go
package main

import (
    "github.com/containernetworking/cni/pkg/skel"
    "github.com/containernetworking/cni/pkg/types"
)

type NetConf struct {
    types.NetConf
    DatapathType string `json:"datapath_type"`
    DevArgs      string `json:"dev_args"`
}

func cmdAdd(args *skel.CmdArgs) error {
    // 1. 解析配置
    conf := &NetConf{}
    json.Unmarshal(args.StdinData, conf)

    // 2. 创建 OVS 端口
    ovsPort := "cni-" + args.ContainerID[:8]
    ovs-vsctl add-br br0 -- \
        add-port br0 ${ovsPort} -- \
        set Interface ${ovsPort} \
        type=dpdkvhostuser \
        options:vhost-sock-path=${args.Netns}/${ovsPort}.sock

    // 3. 配置网络命名空间
    ipam := allocateIP(conf.CIDR)
    ns, _ := netns.GetFromPath(args.Netns)
    ns.Do(func() {
        exec.Command("ip", "link", "set", "eth0", "master", ovsPort).Run()
        exec.Command("ip", "addr", "add", ipam, "dev", "eth0").Run()
        exec.Command("ip", "link", "set", "eth0", "up").Run()
    })

    return nil
}
```

### 4.3 CNI 配置

```json
// /etc/cni/net.d/10-dpdk.conf
{
  "cniVersion": "0.4.0",
  "name": "dpdk-network",
  "type": "dpdkcni",
  "datapath_type": "netdev",
  "dev_args": "0000:3d:00.0",
  "ipam": {
    "type": "host-local",
    "subnet": "10.10.0.0/16"
  }
}
```

## 5. Kubernetes 网络

### 5.1 Multus CNI

```
Multus 允许多网络接口：

┌─────────────────────────────────────────────────────────────┐
│                    Multus 多网络                            │
│                                                              │
│  Pod                                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  eth0: 默认网络 (flannel)                           │  │
│  │  net0: OVS-DPDK 网络 (DPDK)                         │  │
│  │  net1: SRIOV VF (HW offload)                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

Multus 的商业意义是：一个 Pod 可以同时接入“普通管理网络”和“高速数据网络”。

例如一个 5G UPF Pod：

```
┌─────────────────────────────────────────────────────────────┐
│                         UPF Pod                             │
│                                                             │
│  eth0                                                       │
│    - Kubernetes 默认网络                                    │
│    - 用于健康检查、日志、控制面 API                         │
│                                                             │
│  net0                                                       │
│    - N3/N6 高速用户面网络                                   │
│    - SR-IOV VF 或 OVS-DPDK vhost-user                       │
│    - DPDK/UPF 真正收发用户流量                              │
└─────────────────────────────────────────────────────────────┘
```

流量路径通常会变成：

```text
控制流量:
  UPF Pod eth0
    -> veth
    -> Kubernetes 默认 CNI
    -> service / apiserver / monitoring

用户面流量:
  UPF DPDK process
    -> net0 对应的 VF 或 vhost-user 接口
    -> NIC / OVS-DPDK / VPP
    -> 外部网络
```

> [!tip] 配套实验
> 如果只看图仍然抽象，可以先跑仓库里的 `practice/cnf_multus_demo/`。
> 它用 Linux network namespace 模拟 `业务 Pod -> 双网口 CNF Pod -> 外部网络`，
> 不依赖真实 Kubernetes，也能把 Multus 多网口和 CNF 转发路径跑通。

### 5.2 Multus + OVS 配置

```yaml
# network-attachment-definition.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ovs-dpdk-net
spec:
  config: '{
      "type": "ovs-dpdk",
      "datapath_type": "netdev",
      "bridge": "br0"
  }'
---
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: ovs-dpdk-net
spec:
  containers:
  - name: dpdk-app
    image: dpdk-app:latest
    securityContext:
      privileged: true
    resources:
      limits:
        hugepages-2Mi: 1Gi
        intel.com/dpdk: '1'
```

### 5.3 DPDK 设备插件

```yaml
# dpdk-device-plugin.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dpdk-device-plugin
spec:
  selector:
    matchLabels:
      app: dpdk-device-plugin
  template:
    metadata:
      labels:
        app: dpdk-device-plugin
    spec:
      hostNetwork: true
      containers:
        - name: dpdk-plugin
          image: intel/dpdk-device-plugin:latest
          securityContext:
            privileged: true
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
            - name: hugepages
              mountPath: /mnt/hugepages
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: hugepages
          emptyDir:
            medium: HugePages
```

## 6. SR-IOV 容器

### 6.1 SR-IOV 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SR-IOV 容器网络                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               Physical Function (PF)                   │  │
│  │               (ovs-dpdk 管理)                        │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓         ↓         ↓                                │
│  ┌────────┐ ┌────────┐ ┌────────┐                            │
│  │  VF 0  │ │  VF 1  │ │  VF 2  │                            │
│  │(Pod A) │ │(Pod B) │ │(Pod C) │                            │
│  └────────┘ └────────┘ └────────┘                            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 SR-IOV 配置

SR-IOV 这里也要分清楚三件事：

```text
PF:
  物理网卡上的 Physical Function，例如 eth0 / ens3f0

VF:
  从 PF 切出来的 Virtual Function，每个 VF 都是一个独立 PCI function

Pod 绑定 VF:
  不是 Pod 自己去 echo/sysfs，而是 kubelet + device plugin + SR-IOV CNI
  把某个 VF 分配给这个 Pod
```

第一步是在 Host 上从 PF 创建 VF：

```bash
# 在 PF eth0 上创建 4 个 VF
echo 4 > /sys/class/net/eth0/device/sriov_numvfs
```

创建后，每个 VF 都会有自己的 PCI 地址。比如查看 VF 1：

```bash
readlink /sys/class/net/eth0/device/virtfn1
# ../../../0000:3b:10.1
```

这里的 `0000:3b:10.1` 才是 VF 1 的 PCI BDF。DPDK 绑定驱动时绑定的是这个 PCI
地址，不是 `eth0 vf 1`。

Host 可以通过 PF 配置 VF 的属性：

```bash
# 配置 VF 1 的 MAC/VLAN
ip link set eth0 vf 1 mac 00:11:22:33:44:55
ip link set eth0 vf 1 vlan 100

# 有些网卡/场景还会配置 trust/spoofchk
ip link set eth0 vf 1 trust on
ip link set eth0 vf 1 spoofchk off
```

这两个参数控制 VF 的安全边界：

```text
spoofchk on:
  PF/NIC 会检查 VF 发出的包
  如果源 MAC/VLAN 和 Host 给这个 VF 配的不一致，可能直接丢弃
  适合普通租户 VM/Pod，防止伪造 MAC/VLAN

spoofchk off:
  放宽反欺骗检查
  VF 可以发出非预配置 MAC/VLAN 的包
  适合路由器、防火墙、LB、网关、抓包/镜像等 CNF

trust off:
  VF 权限较低
  不能随便开混杂模式、改 MAC、处理更多 VLAN/多播等能力

trust on:
  提高 VF 权限
  允许某些高级行为，例如 promisc、更多 MAC/VLAN/多播能力
  具体能力取决于网卡和驱动
```

普通业务 Pod 不应该随便开：

```text
trust on + spoofchk off
```

因为这相当于放宽了租户隔离。CNF 场景经常需要它，是因为 CNF 本来就要像网络设备：

```text
防火墙:
  可能需要看到/转发不同源 MAC 的流量

路由器/网关:
  可能处理多个二层邻居和 VLAN

负载均衡/NAT:
  可能改写地址、转发非本机源地址流量

流量镜像/IDS:
  只有在镜像流量被明确设计成直接送入 VF/DPDK/AF_XDP 时才适合
  如果镜像流量还要经过 veth、Service、iptables、overlay，多数情况下不适合作为高性能 CNF
```

特别是 IDS/流量镜像，不应该只因为“它是网络功能”就默认放进 CNF。要先问清楚：

```text
镜像流量从哪里来？
是交换机 / NIC / OVS / eBPF / sidecar 镜像？
进入 IDS Pod 前经过了几次 veth/bridge/overlay/封装？
是否保留原始五元组、VLAN、时间戳和包长？
是否会乱序、采样、截断或被 kube-proxy/iptables 改写？
```

如果镜像路径不可控，IDS 跑成 CNF 反而可能只是在分析“被平台处理过的二手流量”。
这种场景更常见的做法是：

```text
硬件 TAP / SPAN / ERSPAN
  -> 专用采集节点
  -> DPDK / AF_XDP / PF_RING / Suricata

或：

OVS / eBPF 明确镜像
  -> 直接送到采集接口
  -> 避免走普通 Service/veth 链路
```

所谓“检测东西向流量”也有前提：被检测的东西向流量必须经过镜像点。

```text
可以被 OVS 镜像看到:
  VM/CNF/Pod 的数据口都接在同一个 OVS-DPDK bridge 上
  或跨节点流量必须经过 OVS tunnel / OVS physical port

不一定能被 OVS 镜像看到:
  Pod-to-Pod 走 Cilium/eBPF 直连，没有经过 OVS
  SR-IOV VF 直接进 NIC hardware，绕过 Host OVS
  同节点流量在 veth/netkit fast path 里直接 redirect
  overlay/encryption 让 OVS 只能看到外层封装
```

所以更准确的说法是：

```text
IDS CNF 只能检测经过它所在镜像点的数据面流量；
如果东西向流量绕过 OVS，就需要在对应数据面上镜像：
  eBPF 层
  NIC/Switch 层
  SmartNIC/DPU 层
  或每个节点都部署采集点
```

接下来有两种模式。

#### 模式 A：kernel netdevice VF

这种模式下，VF 仍然是 Linux 网卡。SR-IOV CNI 会把 VF 对应的 netdevice 移进 Pod
network namespace，并命名为 `net1`。

```text
Host:
  PF eth0
    -> VF 1
       -> Linux netdevice

Kubernetes:
  SR-IOV device plugin 发现 VF
  kubelet 把 VF 资源分配给 Pod
  SR-IOV CNI 把 VF netdevice 移进 Pod netns

Pod:
  eth0: 默认 CNI
  net1: VF 网卡
```

Pod 里可以直接看到：

```bash
ip link show net1
ip addr show net1
```

适合：

```text
普通应用通过 socket 使用 VF
应用不直接跑 DPDK
```

#### 模式 B：DPDK/vfio VF

这种模式下，VF 绑定到 `vfio-pci`，作为 PCI 设备分配给 Pod。DPDK 应用在容器里直接
用 PMD 驱动这个 VF。

```bash
# 找到 VF 1 的 PCI 地址
readlink /sys/class/net/eth0/device/virtfn1
# ../../../0000:3b:10.1

# 绑定 VF 到 vfio-pci
modprobe vfio-pci
dpdk-devbind.py -b vfio-pci 0000:3b:10.1
```

Pod 里不一定会看到一个普通 Linux `net1`。它看到的更可能是一个被 device plugin
分配进来的 PCI 设备：

```text
/sys/bus/pci/devices/0000:3b:10.1
/dev/vfio/<group>
```

这里的“分配进 Pod”不是简单靠 mount namespace 完成的。mount namespace 只能解释
“容器里能看到某个路径”，但不能解释“容器进程为什么有权限对这个设备做 ioctl、
mmap、DMA 映射”。vfio 模式下真正起作用的是：

```text
SR-IOV device plugin
  -> 发现 Host 上绑定到 vfio-pci 的 VF
  -> 把这些 VF 作为 Kubernetes extended resource 上报给 kubelet

Pod 调度到节点后：
  -> kubelet 调用 device plugin 的 Allocate()
  -> device plugin 返回要注入容器的 device node / mount / env
  -> kubelet 把结果交给 CRI/container runtime
  -> containerd/runc 写入 OCI spec
  -> 容器里出现 /dev/vfio/vfio 和 /dev/vfio/<group>
  -> devices cgroup 允许访问对应字符设备的 major/minor
```

也就是说，`/dev/vfio/<group>` 进入容器通常包含两件事：

```text
路径可见性:
  container runtime 把 Host 上的 /dev/vfio/<group>
  作为 device 或 bind mount 放到容器的 /dev/vfio/<group>

访问授权:
  OCI runtime 配置 devices cgroup
  允许容器进程访问这个字符设备的 major/minor
```

`/sys/bus/pci/devices/0000:3b:10.1` 则来自容器里的 sysfs 视图。看到 sysfs 里的 PCI
目录不等于已经获得设备访问权；真正让 DPDK 通过 vfio 操作 PCI BAR、中断和 DMA 的，
是 `/dev/vfio/vfio` 加上对应 IOMMU group 的 `/dev/vfio/<group>`。

DPDK 应用启动后通过 EAL/PMD 接管它：

```bash
dpdk-testpmd -l 2-5 -n 4 -a 0000:3b:10.1 -- -i
```

Kubernetes 里的 Pod spec 通常是请求一个 SR-IOV/DPDK 资源：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-sriov-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: sriov-dpdk-net
spec:
  containers:
    - name: dpdk-app
      image: dpdk-app:latest
      securityContext:
        privileged: true
      resources:
        limits:
          hugepages-2Mi: 1Gi
          example.com/sriov_dpdk: "1"
```

这里 `example.com/sriov_dpdk: "1"` 表示：Pod 要求 kubelet 给它分配 1 个符合条件的
VF。真正把哪一个 VF 分给它，是 SR-IOV device plugin 的调度结果。

所以“容器怎么绑定到 VF 1”的准确答案是：

```text
不是容器手工绑定 VF 1；
而是 Host 先创建并准备 VF；
device plugin 把 VF 作为资源上报给 Kubernetes；
kubelet 给 Pod 分配一个 VF；
SR-IOV CNI / device plugin 把这个 VF 放进 Pod；
DPDK 应用再在 Pod 内接管这个 VF。
```

如果你一定要让某个 Pod 固定拿 VF 1，需要额外的资源池、selector、node policy、
device plugin 配置或 Operator 约束。普通 Kubernetes 调度语义里，Pod 请求的是
“一个符合条件的 VF”，不是“必须拿 eth0 的 VF 1”。

## 7. 性能对比

### 7.1 容器网络性能

| 方案              | 吞吐量   | 延迟   | CPU cycles/pkt |
| ----------------- | -------- | ------ | -------------- |
| **veth + bridge** | ~2 Gbps  | ~100μs | ~400           |
| **OVS (kernel)**  | ~3 Gbps  | ~80μs  | ~300           |
| **OVS-DPDK**      | ~10 Gbps | ~20μs  | ~50            |
| **SR-IOV**        | ~15 Gbps | ~5μs   | ~20            |

### 7.2 优化建议

这几个参数解决的是三类资源问题：

```text
PMD 线程:
  OVS-DPDK 真正轮询网卡队列/virtqueue 的线程

HugePages:
  DPDK mbuf、ring、队列使用的大页内存

CPU isolation:
  把关键 CPU 从普通 Linux 调度干扰中隔离出来
```

原来的示例里 `other_config:dpdk-swd=c0` 不像有效 OVS-DPDK 参数，更合理的写法是：

```bash
# 1. 初始化 DPDK，并指定 DPDK 内存
ovs-vsctl set Open_vSwitch . \
    other_config:dpdk-init=true \
    other_config:dpdk-socket-mem="1024,1024"

# 2. 指定 OVS/DPDK 控制线程使用哪些 CPU
#    0x2 表示 CPU 1
ovs-vsctl set Open_vSwitch . \
    other_config:dpdk-lcore-mask=0x2

# 3. 指定 PMD 轮询线程使用哪些 CPU
#    0x3c = 二进制 111100，表示 CPU 2,3,4,5
ovs-vsctl set Open_vSwitch . \
    other_config:pmd-cpu-mask=0x3c
```

`pmd-cpu-mask` 最关键。OVS-DPDK 的 PMD 线程是 busy polling 模型：

```text
PMD thread
  -> 不断轮询 RX queue / vhost-user queue
  -> 批量收包
  -> 查 OVS flow table
  -> 发到目标 port
```

所以 PMD 线程应该放在专用 CPU 上，尽量不要和普通业务、软中断、kubelet、容器运行时
混跑。

大页需要在 OVS-DPDK 启动前准备好：

```bash
# 配置 1024 个 2MiB hugepages，大约 2GiB
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 挂载 hugetlbfs，路径按发行版/部署习惯调整
mkdir -p /dev/hugepages
mount -t hugetlbfs nodev /dev/hugepages
```

CPU 隔离不是一条运行时命令，而是内核启动参数。通常要写到 GRUB，然后重启：

```text
isolcpus=2-5 nohz_full=2-5 rcu_nocbs=2-5
```

含义是：

```text
isolcpus:
  尽量不让普通调度器把普通任务放到这些 CPU

nohz_full:
  减少这些 CPU 上的周期性 tick 干扰

rcu_nocbs:
  把 RCU callback 从这些 CPU 上移走
```

一个更现实的 CPU 分工示例：

```text
CPU 0:
  OS / interrupt / housekeeping

CPU 1:
  OVS main thread / handler / revalidator

CPU 2-5:
  OVS-DPDK PMD threads

CPU 6-7:
  CNF / VPP / DPDK app
```

不要机械照抄 mask。实际要结合：

```text
NUMA socket
NIC PCIe 所在 socket
queue 数量
vhost-user queue 数量
CNF Pod CPU pinning
```

## 8. 总结

容器网络技术对比：

```
┌─────────────────────────────────────────────────────────────┐
│                    容器网络演进                             │
│                                                              │
│  veth + Bridge → veth/netkit+BPF → OVS-DPDK → SR-IOV       │
│      ↓                 ↓             ↓           ↓          │
│  通用但路径长      通用容器快路径     用户态转发    硬件直通  │
│                                                              │
│  VPP 也可以作为容器网络数据平面                              │
└─────────────────────────────────────────────────────────────┘
```

选择建议：

| 场景                 | 推荐方案                    |
| -------------------- | --------------------------- |
| **开发测试**         | veth + bridge               |
| **一般生产**         | veth + eBPF / OVS kernel    |
| **通用容器网络加速** | veth fast redirect / netkit |
| **网络功能高性能**   | OVS-DPDK / VPP / vhost-user |
| **超高性能**         | SR-IOV                      |

从流量路径角度看：

| 场景                  | 数据面路径                                               | 关键取舍                           |
| --------------------- | -------------------------------------------------------- | ---------------------------------- |
| 普通业务 Pod          | App → socket → Pod kernel → veth → Host bridge/OVS → NIC | 最通用，性能不是极限               |
| veth/netkit fast path | App → socket → Pod kernel → BPF redirect → peer/NIC      | 保留通用语义，同时缩短内核路径     |
| OVS-DPDK/vhost-user   | DPDK/VPP → vhost-user ring → OVS-DPDK flow table → NIC   | 性能高，还能保留 Host vSwitch 编排 |
| SR-IOV Pod            | DPDK app → VF → NIC hardware                             | 性能最高，但平台管控能力变弱       |

---

## 参考资源

- [OVS-DPDK](https://www.openvswitch.org/support/dist-docs/ovs-vswitchd.dpdk.conf.5.txt)
- [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni)
- [DPDK CNI](https://github.com/intel-app/networking-cni)
