---
title: "DPDK 深度探索 ch16a：OVS-DPDK 与 vhost-user 最小实战"
date: 2026-04-10 09:30:00
tags: [dpdk, ovs-dpdk, vhost-user, virtio-net, qemu, kvm, lab]
description: "用两个 QEMU 虚拟机和 OVS-DPDK 搭建最小 vhost-user 实验，观察 virtio-net、Unix socket、Guest memory 共享与 OVS-DPDK 数据路径"
---

# DPDK 深度探索 ch16a：OVS-DPDK 与 vhost-user 最小实战

> [!abstract] 实战目标
> 不先上 OpenStack，也不先接物理 DPDK 网卡。本文只用 OVS-DPDK、QEMU、两个
> VM 和两个 vhost-user socket，搭一个最小可观察实验：Guest 里看到
> `virtio-net`，Host 侧由 OVS-DPDK 作为 vhost-user backend 处理 virtqueue。

> 前置阅读：[[2026-04-09-dpdk-deep-dive-ch16-vhost-user|第十六章：vhost-user 与 virtio 加速]]、
> [[2026-04-09-dpdk-deep-dive-ch26-vhost-user|第二十六章：vhost-user 原理]]、
> [[2026-04-09-dpdk-deep-dive-ch27-memory-dma|第二十七章：内存优化、DMA 与零拷贝]]

## 1. 这个实验要证明什么

OpenStack + OVS-DPDK 的完整环境会引入 Nova、Neutron、ML2、OVN、安全组、
hugepage flavor、NUMA、CPU pinning 等大量配置。它们都重要，但一开始会遮住主线。

本文先只看这条最核心的数据路径：

```text
VM1 virtio-net
  -> QEMU vhost-user socket
  -> OVS-DPDK dpdkvhostuserclient port
  -> OVS userspace datapath
  -> OVS-DPDK dpdkvhostuserclient port
  -> QEMU vhost-user socket
  -> VM2 virtio-net
```

这个实验不需要物理 DPDK 网卡。它只验证 Host/Guest 之间的 vhost-user 机制：

```text
Guest 看到:
  virtio-net PCI 网卡
  Linux virtio_net driver
  普通 ethX / ensX

Host 看到:
  QEMU 进程
  vhost-user Unix socket
  OVS Interface: type=dpdkvhostuserclient
  OVS datapath_type=netdev
  ovs-vswitchd 使用 DPDK EAL
```

看懂这条线，再去看 OpenStack 会清楚很多：OpenStack 只是帮你自动生成 VM、socket、
OVS port、hugepage、CPU 亲和性和 Neutron 网络配置。

## 2. 实验拓扑

```text
Host
├── ovs-vswitchd
│   └── br-vhu, datapath_type=netdev
│       ├── vhu-vm1, type=dpdkvhostuserclient
│       │   └── /var/run/openvswitch/vhu-vm1.sock
│       └── vhu-vm2, type=dpdkvhostuserclient
│           └── /var/run/openvswitch/vhu-vm2.sock
│
├── qemu-system-x86_64 vm1
│   └── virtio-net-pci
│       └── chardev socket: /var/run/openvswitch/vhu-vm1.sock
│
└── qemu-system-x86_64 vm2
    └── virtio-net-pci
        └── chardev socket: /var/run/openvswitch/vhu-vm2.sock
```

VM 内配置静态 IP：

```text
VM1: 192.168.100.11/24
VM2: 192.168.100.12/24
```

成功以后，从 VM1 ping VM2：

```text
VM1 virtio-net -> vhost-user -> OVS-DPDK -> vhost-user -> VM2 virtio-net
```

## 3. 准备环境

### 3.1 软件要求

需要这些组件：

```text
Linux host with KVM
QEMU >= 2.7
Open vSwitch with DPDK enabled
DPDK hugepage support
一个 Linux cloud image 或普通 qcow2 镜像
```

是否已经启用 OVS-DPDK，可以先看：

```bash
ovs-vswitchd --version
ovs-vsctl get Open_vSwitch . dpdk_initialized
ovs-vsctl get Open_vSwitch . dpdk_version
```

期望看到：

```text
dpdk_initialized: true
dpdk_version: "..."
```

如果 `dpdk_initialized` 不是 `true`，先不要启动 VM，先修 OVS-DPDK 初始化。

### 3.2 hugepage

vhost-user backend 需要 mmap Guest memory，QEMU 的内存必须用共享内存方式暴露给
backend。OVS 官方文档里的典型方式是 hugetlbfs：

```bash
grep HugePages_ /proc/meminfo
mount | grep hugetlbfs
```

如果没有 hugepage，可以先准备 2 MB hugepage：

```bash
sudo sysctl -w vm.nr_hugepages=2048
sudo mkdir -p /dev/hugepages
sudo mount -t hugetlbfs hugetlbfs /dev/hugepages
```

这里分配的是 2048 个 2 MB hugepage，大约 4 GB。本文两个 VM 每个用 1 GB，给
OVS-DPDK 也留一些余量。

## 4. 配置 OVS-DPDK

### 4.1 打开 DPDK 初始化

如果 OVS 已经是 DPDK 版本，但还没有启用 DPDK EAL：

```bash
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-init=true
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="1024"
sudo ovs-vsctl --no-wait set Open_vSwitch . other_config:pmd-cpu-mask="0x6"
```

这些值的含义：

```text
dpdk-init=true:
  ovs-vswitchd 启动时初始化 DPDK EAL

dpdk-socket-mem="1024":
  从 NUMA socket 预留 1024 MB DPDK 内存

pmd-cpu-mask="0x6":
  用 CPU1、CPU2 做 PMD 线程
```

改完这些全局 DPDK 配置后，需要重启 `ovs-vswitchd`：

```bash
sudo systemctl restart openvswitch-switch
```

不同发行版服务名可能是 `openvswitch`、`openvswitch-switch` 或手工启动的
`ovs-ctl`。关键不是服务名，而是让新的 `other_config` 生效。

确认：

```bash
ovs-vsctl get Open_vSwitch . dpdk_initialized
ovs-vsctl get Open_vSwitch . other_config
```

### 4.2 创建 userspace bridge

```bash
sudo ovs-vsctl --may-exist add-br br-vhu -- set bridge br-vhu datapath_type=netdev
```

`datapath_type=netdev` 是 OVS userspace datapath。OVS-DPDK 的 vhost-user 端口不走
Linux kernel datapath。

### 4.3 创建两个 vhost-user-client 端口

现代 OVS 推荐使用 `dpdkvhostuserclient`，而不是老的 `dpdkvhostuser`。

区别是：

```text
dpdkvhostuser:
  OVS 是 socket server
  QEMU 是 socket client
  OVS 重启后通常需要重启 VM
  该模式已经被 OVS 标记为 deprecated

dpdkvhostuserclient:
  QEMU 是 socket server
  OVS 是 socket client
  OVS 重启后可以重新连回 VM
  这是现在推荐的模式
```

创建端口：

```bash
sudo ovs-vsctl --may-exist add-port br-vhu vhu-vm1 \
  -- set Interface vhu-vm1 type=dpdkvhostuserclient \
  options:vhost-server-path=/var/run/openvswitch/vhu-vm1.sock

sudo ovs-vsctl --may-exist add-port br-vhu vhu-vm2 \
  -- set Interface vhu-vm2 type=dpdkvhostuserclient \
  options:vhost-server-path=/var/run/openvswitch/vhu-vm2.sock
```

此时 socket 文件可能还不存在，因为 `dpdkvhostuserclient` 模式下 server 是 QEMU。
OVS 会等 QEMU 创建 socket 后再连接。

观察 OVS 配置：

```bash
ovs-vsctl show
ovs-vsctl list Interface vhu-vm1
ovs-vsctl list Interface vhu-vm2
```

重点看：

```text
type                : dpdkvhostuserclient
options             : {vhost-server-path="/var/run/openvswitch/vhu-vm1.sock"}
admin_state         : up
link_state          : down or up
```

VM 还没起来时，`link_state` 通常是 `down`，这是正常的。

## 5. 启动 VM

### 5.1 QEMU 参数结构

每个 VM 的网络参数由三层组成：

```text
-chardev socket:
  创建 vhost-user Unix socket

-netdev type=vhost-user:
  把这个 socket 作为 virtio-net 的 backend

-device virtio-net-pci:
  给 Guest 暴露一块 virtio-net PCI 网卡
```

内存参数也很关键：

```text
-object memory-backend-file,...,mem-path=/dev/hugepages,share=on
-numa node,memdev=mem
-mem-prealloc
```

`share=on` 的意思是这段 Guest memory 可以被 vhost-user backend mmap。没有这个，
OVS-DPDK 即使连上 socket，也不能正确访问 Guest virtqueue 和 packet buffer。

### 5.2 启动 VM1

下面假设镜像是 `/var/lib/libvirt/images/vm1.qcow2`。实际路径按你的环境替换。

```bash
sudo qemu-system-x86_64 \
  -name vm1 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 2 \
  -m 1024M \
  -object memory-backend-file,id=mem,size=1024M,mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -mem-prealloc \
  -drive file=/var/lib/libvirt/images/vm1.qcow2,if=virtio,cache=none,format=qcow2 \
  -chardev socket,id=char0,path=/var/run/openvswitch/vhu-vm1.sock,server=on,wait=off \
  -netdev type=vhost-user,id=net0,chardev=char0,vhostforce \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:11 \
  -serial mon:stdio \
  -nographic
```

### 5.3 启动 VM2

另开一个终端：

```bash
sudo qemu-system-x86_64 \
  -name vm2 \
  -enable-kvm \
  -machine q35,accel=kvm \
  -cpu host \
  -smp 2 \
  -m 1024M \
  -object memory-backend-file,id=mem,size=1024M,mem-path=/dev/hugepages,share=on \
  -numa node,memdev=mem \
  -mem-prealloc \
  -drive file=/var/lib/libvirt/images/vm2.qcow2,if=virtio,cache=none,format=qcow2 \
  -chardev socket,id=char0,path=/var/run/openvswitch/vhu-vm2.sock,server=on,wait=off \
  -netdev type=vhost-user,id=net0,chardev=char0,vhostforce \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:00:00:12 \
  -serial mon:stdio \
  -nographic
```

VM 启动后，Host 上应该能看到 socket：

```bash
ls -l /var/run/openvswitch/vhu-vm*.sock
ss -xl | grep vhu-vm
```

OVS Interface 状态应该从 `down` 变成 `up`：

```bash
ovs-vsctl list Interface vhu-vm1
ovs-vsctl list Interface vhu-vm2
```

## 6. Guest 内配置网络

进入 VM1：

```bash
ip link
ip addr add 192.168.100.11/24 dev eth0
ip link set eth0 up
```

进入 VM2：

```bash
ip link
ip addr add 192.168.100.12/24 dev eth0
ip link set eth0 up
```

有些发行版里网卡名不是 `eth0`，可能是 `ens3`、`enp0s3`。以 `ip link` 看到的
virtio 网卡为准。

从 VM1 测试：

```bash
ping -c 3 192.168.100.12
```

从 VM2 测试：

```bash
ping -c 3 192.168.100.11
```

如果 ping 通，这条路径已经跑起来了：

```text
VM1 kernel virtio_net
  -> VM1 TX virtqueue
  -> QEMU vhost-user socket
  -> OVS-DPDK vhu-vm1
  -> br-vhu userspace datapath
  -> OVS-DPDK vhu-vm2
  -> VM2 RX virtqueue
  -> VM2 kernel virtio_net
```

## 7. 观察什么

### 7.1 OVS 侧

看 bridge 和端口：

```bash
ovs-vsctl show
ovs-vsctl list-br
ovs-vsctl list-ports br-vhu
```

看 vhost 端口状态：

```bash
ovs-vsctl list Interface vhu-vm1
ovs-vsctl list Interface vhu-vm2
```

重点字段：

```text
type:
  dpdkvhostuserclient

options:
  vhost-server-path

statistics:
  rx_packets
  tx_packets
  rx_bytes
  tx_bytes
  ovs_tx_retries

status:
  driver_name
  if_descr
  numa_id
```

看 datapath：

```bash
ovs-appctl dpif/show
ovs-appctl dpctl/show
```

看 PMD：

```bash
ovs-appctl dpif-netdev/pmd-rxq-show
ovs-appctl dpif-netdev/pmd-stats-show
```

这些命令能回答几个关键问题：

```text
端口是否被 OVS userspace datapath 接管？
vhost-user socket 是否连接？
PMD 线程是否在 poll 这个 vhost 端口？
包是否真的经过 OVS-DPDK，而不是 Linux bridge？
```

### 7.2 QEMU 侧

看 QEMU 参数：

```bash
ps -ef | grep qemu-system
```

重点找这些片段：

```text
-chardev socket,...,path=/var/run/openvswitch/vhu-vm1.sock,server=on
-netdev type=vhost-user,id=net0,chardev=char0,vhostforce
-device virtio-net-pci,netdev=net0
-object memory-backend-file,...,share=on
```

这说明：

```text
QEMU 是 vhost-user socket server
OVS-DPDK 是 vhost-user socket client
Guest 看到 virtio-net PCI 设备
Guest memory 以 share=on 的方式暴露给 backend
```

### 7.3 Guest 侧

在 VM 里看 PCI 和驱动：

```bash
lspci | grep -i virtio
ethtool -i eth0
ip -s link show eth0
```

典型结果：

```text
Ethernet controller: Red Hat, Inc. Virtio network device
driver: virtio_net
```

这就是最容易混淆的地方：Guest 不会看到 OVS-DPDK，也不会看到 Host 物理网卡。Guest
只看到一块 virtio-net 虚拟网卡。

## 8. 这条路径里谁在做 DMA

这个实验没有物理 DPDK 网卡，所以没有“NIC DMA 到 mbuf”的部分。它主要用于观察
vhost-user。

数据路径可以拆成两层：

```text
Guest 内部:
  Guest kernel virtio_net driver
  在 Guest memory 里的 virtqueue 放 descriptor

Host 侧:
  QEMU 把 Guest memory table、vring 地址、eventfd 通过 vhost-user socket 交给 OVS-DPDK
  OVS-DPDK mmap Guest memory
  OVS-DPDK 读写 virtqueue
  OVS-DPDK 在 vhost port 之间转发 packet
```

如果这个实验再接一块物理 DPDK NIC，路径会变成：

```text
Physical NIC
  -> NIC DMA writes Host mbuf
  -> DPDK PMD rx_burst
  -> OVS-DPDK userspace datapath
  -> vhost-user backend writes Guest virtqueue buffer
  -> Guest virtio_net receives packet
```

反方向：

```text
Guest virtio_net TX
  -> Guest TX virtqueue
  -> OVS-DPDK vhost-user backend reads Guest buffer
  -> OVS-DPDK userspace datapath
  -> DPDK PMD tx_burst
  -> NIC DMA reads Host mbuf
  -> wire
```

所以不要把 `rte_eth_rx_burst()`、`rte_eth_tx_burst()` 和 vhost-user 混成一件事：

```text
rte_eth_rx_burst / tx_burst:
  面向物理/虚拟 ethdev port 的 RX/TX descriptor

vhost-user:
  面向 Guest virtqueue 的 descriptor

OVS-DPDK:
  把这些 port 都抽象成 netdev，在 userspace datapath 里做转发
```

## 9. 常见故障

### 9.1 `dpdk_initialized` 不是 `true`

先看日志：

```bash
journalctl -u openvswitch-switch -n 200
ovs-appctl vlog/list
```

常见原因：

```text
hugepage 不够
dpdk-socket-mem 配错 NUMA socket
OVS 不是带 DPDK 构建的版本
ovs-vswitchd 没有重启
```

### 9.2 vhost 端口一直 down

检查 socket 角色是否匹配。

本文用的是：

```text
OVS:
  type=dpdkvhostuserclient
  options:vhost-server-path=/var/run/openvswitch/vhu-vm1.sock

QEMU:
  -chardev socket,...,path=/var/run/openvswitch/vhu-vm1.sock,server=on,wait=off
```

也就是：

```text
QEMU server
OVS client
```

如果你改成 `type=dpdkvhostuser`，角色就反过来了，QEMU 参数也要跟着变。

### 9.3 QEMU 报 hugepage 或 memory backend 错误

检查：

```bash
grep HugePages_ /proc/meminfo
mount | grep huge
ls -ld /dev/hugepages
```

两个 VM 都用了 1 GB，启动时还加了 `-mem-prealloc`，所以 hugepage 必须真实可用。
如果只是想先验证 socket，也可以把 VM 内存调小，例如 512 MB。

### 9.4 VM 里没有 eth0

先看：

```bash
ip link
lspci | grep -i virtio
dmesg | grep -i virtio
```

如果有 virtio PCI 设备但没有网卡，检查 Guest 内核是否有 `virtio_net` 驱动。

### 9.5 ping 不通

按这个顺序查：

```text
1. VM1/VM2 IP 是否在同一个网段
2. VM 里的网卡是否 up
3. OVS vhost Interface link_state 是否 up
4. OVS Interface statistics 是否增长
5. Guest 防火墙是否丢 ICMP
6. 两个 vhost 端口是否在同一个 br-vhu
```

命令：

```bash
ovs-vsctl list Interface vhu-vm1
ovs-vsctl list Interface vhu-vm2
ovs-appctl dpif/show
```

## 10. 和 OpenStack 的对应关系

这个手工实验和 OpenStack 的对应关系大概是：

| 手工实验对象                | OpenStack 里谁负责                              |
| --------------------------- | ----------------------------------------------- |
| QEMU 进程                   | Nova compute / libvirt                          |
| `virtio-net-pci`            | Nova/libvirt domain XML                         |
| hugepage memory backend     | Nova flavor + image metadata + libvirt          |
| vhost-user socket path      | Nova + Neutron port binding                     |
| `dpdkvhostuserclient` port  | Neutron OVS agent / OVSDB                       |
| `br-vhu`                    | br-int / br-phy / provider bridge               |
| OVS-DPDK userspace datapath | ovs-vswitchd + DPDK PMD                         |
| 物理 DPDK NIC               | Neutron bridge mapping + OVS DPDK physical port |

OpenStack 做的是自动化编排，不改变 vhost-user 的本质：

```text
Guest virtio-net frontend
  <-> QEMU vhost-user socket
  <-> OVS-DPDK vhost-user backend
  <-> OVS userspace datapath
```

理解本文这个最小实验后，再看 OpenStack 配置时，可以主动去找：

```text
libvirt XML 里的 <interface type='vhostuser'>
socket path
hugepage backing
NUMA / CPU pinning
OVS Interface type=dpdkvhostuserclient
OVS bridge datapath_type=netdev
PMD thread 和 RX queue 绑定
```

## 11. 下一步

这个实验只覆盖 vhost-user 机制。后续可以按风险从低到高继续加：

```text
1. 两个 VM + OVS-DPDK + vhost-user
   观察 Host/Guest virtqueue 连接

2. 加一块物理 DPDK NIC
   观察 NIC PMD、mbuf、rx_burst、tx_burst

3. 用 OpenStack 自动创建同样的 VM
   观察 Nova/Neutron 如何生成 socket、XML 和 OVS port

4. 加 DSA/dmadev
   观察 vhost async copy offload

5. 换成 vDPA
   观察 virtqueue datapath 如何被硬件卸载
```

## 12. 参考资料

- Open vSwitch, "Open vSwitch with DPDK", https://docs.openvswitch.org/en/latest/intro/install/dpdk/
- Open vSwitch, "DPDK vHost User Ports", https://docs.openvswitch.org/en/latest/topics/dpdk/vhost-user/
- QEMU, "vhost-user back ends", https://www.qemu.org/docs/master/system/devices/virtio/vhost-user.html
- QEMU, "Vhost-user Protocol", https://www.qemu.org/docs/master/interop/vhost-user.html
