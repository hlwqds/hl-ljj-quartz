---
title: "VPP 深入探讨 ch19a：memif 内存接口"
date: 2026-05-26
tags: [vpp, fd.io, memif, dpdk, cnf, container, shared-memory, vhost-user]
description: "深入解析 VPP memif：共享内存接口、master/slave、VPP-to-VPP、VPP-to-DPDK、容器/CNF 场景以及与 vhost-user 的区别"
---

# VPP 深入探讨 ch19a：memif 内存接口

> [!abstract] 核心要点
> memif（memory interface）是 VPP/FD.io 生态里的共享内存 packet 接口。
> 它适合 VPP-to-VPP、VPP-to-DPDK app、同节点容器间高性能连接。
> 和 vhost-user 相比，memif 更轻、更偏 VPP/FD.io；vhost-user 更偏
> virtio/QEMU/OVS-DPDK/VM 生态。

> [!info] 相关章节
> - [[2026-04-09-vpp-deep-dive-ch18-vpp-kubernetes|VPP + Kubernetes]]
> - [[2026-04-09-vpp-deep-dive-ch19-vpp-dpdk|VPP + DPDK]]
> - [[2026-04-09-dpdk-deep-dive-ch27-container-networking|DPDK 容器网络]]

## 1. memif 解决什么问题

同一台机器上，两个用户态网络程序要高速交换 packet，普通方式通常太重：

```text
socket:
  进入内核协议栈，开销大

veth/tap:
  经过 Linux netdev/skb/qdisc/tc 等路径

共享内存:
  两个进程直接共享 packet buffer 和 ring
```

memif 的目标就是：

```text
两个用户态 packet processor
  -> 通过共享内存 ring 交换包
  -> 避免 Linux kernel 网络栈
```

典型场景：

```text
VPP <-> VPP
VPP <-> DPDK app
VPP container <-> VPP host
CNF A <-> CNF B
traffic splitter <-> IDS / recorder
```

## 2. 流量路径

以两个 VPP 实例为例：

```text
┌──────────────────────────────┐
│ VPP A                         │
│                               │
│  memif interface              │
│    -> memif ring              │
│    -> shared memory           │
└──────────────┬───────────────┘
               │ Unix socket 建连 + 共享内存映射
               ▼
┌──────────────────────────────┐
│ VPP B                         │
│                               │
│  shared memory                │
│    -> memif ring              │
│    -> memif interface         │
└──────────────────────────────┘
```

真正的数据路径是：

```text
VPP graph node
  -> memif tx ring
  -> shared memory buffer
  -> peer memif rx ring
  -> peer VPP graph node
```

Unix socket 主要用于建立连接和协商，packet 数据不靠 Unix socket 一包一包传。

## 3. master/slave 和 socket

memif 连接两端要使用相同的 socket 文件和 id，并且角色相反：

```text
VPP A:
  socket: /run/vpp/memif-a-b.sock
  id:     0
  role:   master

VPP B:
  socket: /run/vpp/memif-a-b.sock
  id:     0
  role:   slave
```

一个常见 VPP CLI 形态：

```bash
# VPP A
create memif socket id 1 filename /run/vpp/memif-a-b.sock
create interface memif id 0 socket-id 1 master
set interface state memif1/0 up
set interface ip address memif1/0 10.10.1.1/24

# VPP B
create memif socket id 1 filename /run/vpp/memif-a-b.sock
create interface memif id 0 socket-id 1 slave
set interface state memif1/0 up
set interface ip address memif1/0 10.10.1.2/24
```

注意：不同 VPP 版本的接口名显示可能略有差异，排障时以 `show interface` 为准。

## 4. VPP-to-DPDK app

DPDK 也有 memif PMD，应用可以通过 `net_memif` 创建虚拟设备。

示意：

```text
VPP
  -> memif socket / ring
  -> DPDK net_memif PMD
  -> DPDK app mbuf pipeline
```

DPDK testpmd 的典型形态：

```bash
# server side
dpdk-testpmd -l 0-1 \
  --vdev=net_memif0,role=server,socket=/run/memif.sock \
  -- -i

# client side
dpdk-testpmd -l 2-3 \
  --vdev=net_memif0,role=client,socket=/run/memif.sock \
  -- -i
```

这里 DPDK 用的是 `server/client` 术语，VPP CLI 常见的是 `master/slave` 术语。
不要把名字背死，关键是：两端角色要匹配，socket/id 要一致。

## 5. 容器/CNF 场景

在容器里使用 memif 时，最关键的是共享 socket 路径和权限。

```text
Host / Pod A:
  /run/vpp/memif-a-b.sock

Container / Pod B:
  mount 同一个 socket 目录

VPP/DPDK process:
  使用同一个 socket path 建立 memif 连接
```

Kubernetes 里通常需要：

```text
volumeMounts:
  把 /run/vpp 或 /var/run/memif 挂进 Pod

securityContext:
  允许 CNF 访问共享内存、hugepage、设备

Multus / annotation / CRD:
  约定 socket path、接口 tag、对端信息
```

memif 接口本身不是 Kubernetes 标准 CNI 自动创建的 Linux `net1`。它更像：

```text
CNF 应用 / VPP agent
  -> 在 VPP/DPDK 进程里创建 memif interface

CNI / Multus / Operator
  -> 负责把 socket 目录、权限、metadata 和生命周期接起来
```

## 6. 和 vhost-user 的区别

| 维度 | memif | vhost-user |
| --- | --- | --- |
| 生态 | FD.io/VPP | virtio/vhost/QEMU/OVS-DPDK |
| 典型对象 | VPP-to-VPP、VPP-to-DPDK app | VM/CNF/OVS-DPDK/QEMU |
| 数据结构 | memif ring + shared memory | virtqueue descriptor/avail/used ring |
| 控制面 | memif socket/control protocol | vhost-user Unix socket protocol |
| VM 兼容性 | 不是 virtio-net 生态 | 强，天然连接 virtio/vhost |
| OVS-DPDK | 不是最主流入口 | 一等端口类型 |
| VPP | 很自然 | 也支持，但更偏 virtio 生态 |

选型可以这样记：

```text
VPP <-> VPP:
  优先考虑 memif

VPP <-> DPDK app:
  memif 很合适

VPP/CNF <-> OVS-DPDK:
  vhost-user 更常见

VM <-> Host userspace vSwitch:
  vhost-user
```

## 7. 和 CNI 的职责边界

memif 容器场景里，Kubernetes 依然只负责声明和编排：

```text
Kubernetes:
  Pod 生命周期
  volumeMount
  resource request
  annotation / CRD

CNI / Multus:
  Pod 网络命名空间
  Linux eth0/net1
  IP/route

VPP/DPDK app:
  memif interface
  socket/id/role
  packet processing
```

所以不要把下面两件事混在一起：

```text
CNI 创建 net1:
  Linux netdev，ip link 能看到

VPP 创建 memif:
  VPP 内部接口，vppctl show interface 才能看到
```

## 8. 排障命令

VPP 侧：

```bash
vppctl show interface
vppctl show interface address
vppctl show hardware
vppctl show trace
```

文件和 socket：

```bash
ls -l /run/vpp/
ss -xl | grep memif
```

DPDK 侧：

```bash
dpdk-testpmd -- -i
testpmd> show port info all
testpmd> show port stats all
```

Kubernetes 侧：

```bash
kubectl describe pod <pod>
kubectl get network-attachment-definition
kubectl logs <vpp-agent-or-cnf>
```

## 9. 总结

memif 是 VPP 生态里非常重要的进程间高速接口：

```text
轻量
共享内存
适合 VPP/DPDK app 之间交换 packet
不经过 Linux kernel 网络栈
```

但它不是 vhost-user 的通用替代品：

```text
需要接 VM / OVS-DPDK / virtio 生态:
  vhost-user 更自然

两端都是 VPP/FD.io/DPDK app:
  memif 更自然
```

---

## 参考资料

- [FD.io VPP memif CLI reference](https://docs.fd.io/vpp/22.02/cli-reference/clis/clicmd_src_plugins_memif.html)
- [FD.io VPP libmemif example setup](https://docs.fd.io/vpp/22.02.0/interfacing/libmemif/example_setup_doc.html)
- [DPDK memif Poll Mode Driver](https://doc.dpdk.org/guides-24.07/nics/memif.html)
- [FD.io: Connecting Two VPP Instances](https://docs.fd.io/vpp/25.02/gettingstarted/progressivevpp/twovppinstances.html)
