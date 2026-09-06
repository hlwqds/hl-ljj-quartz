---
title: "DPDK 深度探索 ch35a：SR-IOV 与 VF 实战补充"
date: 2026-04-10 11:30:00
tags: [dpdk, sriov, vf, pci, pf, sr-iov, vfio, virtual-function, cloud]
description: "从实战角度梳理 SR-IOV VF 的创建、配置、VFIO 绑定、VM/容器/DPDK 使用方式、安全边界与排障方法"
---

# DPDK 深度探索 ch35a：SR-IOV 与 VF 实战补充

> [!abstract] 核心要点
> SR-IOV 把一块物理 PCIe 网卡切成一个 PF 和多个 VF。PF 留在 Host 侧做管理和资源控制，
> VF 作为独立 PCI function 分给 VM、容器或 DPDK 应用。VF 的优势是低延迟、高吞吐、
> 少 Host datapath 参与；代价是可编排能力、可观测性和安全策略都更依赖硬件和 PF 驱动。

> 前置阅读：[[ch35-sr-iov|第三十五章：SR-IOV 与 VF 管理机制]]、
> [[ch2-uio-vfio-iommu|第二章：UIO/VFIO/IOMMU]]、
> [[ch27-container-networking|第二十七章：容器网络与 DPDK]]。

## 1. 先把边界说清楚

SR-IOV 容易被一句“把网卡直通给 VM”讲得过于简单。更准确的分工是：

```text
PF (Physical Function):
  完整 PCIe function
  留在 Host
  由 PF 驱动管理硬件资源、VF 数量、VF MAC/VLAN/rate/trust/spoofchk

VF (Virtual Function):
  从 PF 派生出的轻量 PCIe function
  有自己的 PCI BDF、BAR、MSI-X、队列资源
  可分配给 VM、Pod 或 Host 上的 DPDK 进程
```

典型路径：

```text
VM / Pod / DPDK app
  -> VF PCI function
  -> NIC embedded switch / queue / scheduler
  -> wire
```

它绕过的是 Host kernel/OVS/vhost 这类软件数据面，不是绕过所有控制面。PF 驱动和
NIC firmware 仍然在决定 VF 能做什么。

## 2. SR-IOV 适合什么，不适合什么

适合：

```text
低延迟 VM/CNF
NFV 网关、防火墙、负载均衡
DPDK 应用直接驱动 VF
Kubernetes SR-IOV Device Plugin + SR-IOV CNI
希望减少 vhost-user/virtio/OVS-DPDK 软件路径开销
```

不适合：

```text
需要 Host vSwitch 做细粒度安全组、镜像、ACL、可观测性
需要频繁热迁移 VM
需要每个租户都走统一 overlay / service chain
VF 数量不够或硬件队列资源不足
不了解 trust/spoofchk/VLAN 安全边界的多租户环境
```

一句话：

> SR-IOV 是性能优先的路径，不是平台管控最灵活的路径。

## 3. PF、VF 和 PCI 设备关系

创建 VF 后，Host 上会多出新的 PCI function：

```text
0000:3d:00.0  PF
0000:3d:00.1  VF 0
0000:3d:00.2  VF 1
0000:3d:00.3  VF 2
```

sysfs 关系：

```text
/sys/bus/pci/devices/0000:3d:00.0/
  sriov_totalvfs
  sriov_numvfs
  virtfn0 -> ../0000:3d:00.1
  virtfn1 -> ../0000:3d:00.2

/sys/bus/pci/devices/0000:3d:00.1/
  physfn -> ../0000:3d:00.0
```

查看：

```bash
PF=0000:3d:00.0

cat /sys/bus/pci/devices/$PF/sriov_totalvfs
cat /sys/bus/pci/devices/$PF/sriov_numvfs
readlink -f /sys/bus/pci/devices/$PF/virtfn*
```

`sriov_totalvfs` 是硬件/驱动允许的最大 VF 数，`sriov_numvfs` 是当前启用的 VF 数。

## 4. 创建和删除 VF

### 4.1 前置条件

BIOS/UEFI 里通常需要打开：

```text
VT-d / AMD-Vi
SR-IOV
Above 4G decoding
```

内核启动参数通常需要：

```text
intel_iommu=on
```

或：

```text
amd_iommu=on
```

确认 PF 支持 SR-IOV：

```bash
lspci -vv -s 0000:3d:00.0 | grep -i -A20 "Single Root I/O Virtualization"
```

确认 PF 当前驱动：

```bash
lspci -nnk -s 0000:3d:00.0
```

### 4.2 创建 VF

```bash
PF=0000:3d:00.0

cat /sys/bus/pci/devices/$PF/sriov_totalvfs
echo 8 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs
readlink -f /sys/bus/pci/devices/$PF/virtfn*
lspci -nn | grep -i "Virtual Function"
```

如果要把 VF 数量从 8 改成 16，很多驱动要求先清零：

```bash
echo 0 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs
echo 16 | sudo tee /sys/bus/pci/devices/$PF/sriov_numvfs
```

清零前必须确保 VF 没有被 VM、容器或 DPDK 进程占用。

### 4.3 用 PF netdev 配置 VF

如果 PF 在 Linux kernel 驱动下，通常可以用 `ip link` 配置 VF：

```bash
PF_NETDEV=enp61s0f0

ip link show $PF_NETDEV

sudo ip link set $PF_NETDEV vf 0 mac 00:11:22:33:44:55
sudo ip link set $PF_NETDEV vf 0 vlan 100
sudo ip link set $PF_NETDEV vf 0 spoofchk on
sudo ip link set $PF_NETDEV vf 0 trust off
sudo ip link set $PF_NETDEV vf 0 rate 10000

ip -d link show $PF_NETDEV
```

注意两点：

```text
1. 不是所有驱动都支持所有字段。
   mac/vlan/rate/spoofchk/trust 的行为和能力依赖 NIC、PF 驱动和 firmware。

2. 如果 PF 也绑定到 vfio-pci，Host 上通常就没有 PF netdev。
   这时不能再用 ip link set PF vf ... 这种 Linux netdev 命令管理 VF。
```

生产环境里常见做法是：**PF 留给 kernel 驱动管理，VF 绑定给 vfio-pci 或分配给 VM/Pod**。

## 5. VF 的三种使用方式

### 5.1 VM kernel driver 使用 VF

Host 把 VF 通过 VFIO 分配给 QEMU，Guest 里加载厂商 VF 驱动：

```text
Host:
  VF 绑定 vfio-pci
  QEMU 使用 -device vfio-pci,host=0000:3d:00.1

Guest:
  看到一块真实 PCI 网卡
  加载 iavf / ixgbevf / mlx5_core / bnxt_en / ena 等驱动
  应用继续走普通 socket
```

QEMU 示例：

```bash
sudo modprobe vfio-pci
sudo dpdk-devbind.py -b vfio-pci 0000:3d:00.1

qemu-system-x86_64 \
  -enable-kvm \
  -m 4096 \
  -smp 4 \
  -drive file=guest.qcow2,if=virtio,format=qcow2 \
  -device vfio-pci,host=0000:3d:00.1
```

老资料里的 `pci-assign` 已经过时。现在应优先使用 `vfio-pci`。

### 5.2 VM 内 DPDK 使用 VF

这种模式和 5.1 的区别是：Guest 里不让内核网卡驱动接管 VF，而是 Guest 内部再把 VF
绑定给 DPDK：

```text
Host:
  VF 通过 vfio-pci 分配给 VM

Guest:
  VF 再绑定 vfio-pci
  DPDK app / testpmd / OVS-DPDK 直接驱动 VF
```

Guest 内：

```bash
sudo modprobe vfio-pci
sudo dpdk-devbind.py --status
sudo dpdk-devbind.py -b vfio-pci 0000:00:06.0

sudo dpdk-testpmd -l 0-3 -n 4 -a 0000:00:06.0 -- -i
```

这里的 PCI 地址是 Guest 里看到的地址，不一定等于 Host 上的 `0000:3d:00.1`。

### 5.3 Host 或容器内 DPDK 使用 VF

Host 上直接把 VF 绑定到 `vfio-pci`：

```bash
sudo modprobe vfio-pci
sudo dpdk-devbind.py -b vfio-pci 0000:3d:00.1
sudo dpdk-testpmd -l 0-3 -n 4 -a 0000:3d:00.1 -- -i
```

容器场景里，Pod 不是自己 `echo sriov_numvfs`，也不是随便挑一个 VF。通常流程是：

```text
Node:
  PF 创建 VF
  VF 绑定 kernel driver 或 vfio-pci
  SR-IOV Device Plugin 发现 VF 并作为 extended resource 上报

Kubernetes:
  Pod 请求一个 SR-IOV 资源
  kubelet 分配某个符合条件的 VF
  SR-IOV CNI 配置 netdevice 模式，或 device plugin 注入 VFIO device

Pod:
  kernel netdevice 模式看到 net1
  DPDK/vfio 模式看到 /dev/vfio/vfio 和 /dev/vfio/<group>
```

DPDK/vfio 模式下，容器里真正重要的是：

```text
/dev/vfio/vfio
/dev/vfio/<iommu_group>
PCI sysfs 信息
devices cgroup 权限
hugepage mount
```

`/sys/bus/pci/devices/...` 只是设备信息入口；能不能 mmap BAR、中断和 DMA，取决于
VFIO 设备节点和 cgroup 权限。

## 6. DPDK 中怎么看 VF 能力

不要用“这是 VF，所以一定支持某个 offload”来推断。正确方式是运行时查询：

```c
#include <inttypes.h>

#include <rte_ethdev.h>
#include <rte_ether.h>

static void
dump_port_caps(uint16_t port_id)
{
    struct rte_eth_dev_info info;
    struct rte_ether_addr mac;

    rte_eth_dev_info_get(port_id, &info);
    rte_eth_macaddr_get(port_id, &mac);

    printf("driver=%s if_index=%u max_rx_queues=%u max_tx_queues=%u\n",
           info.driver_name,
           info.if_index,
           info.max_rx_queues,
           info.max_tx_queues);

    printf("rx_offload_capa=0x%016" PRIx64 "\n", info.rx_offload_capa);
    printf("tx_offload_capa=0x%016" PRIx64 "\n", info.tx_offload_capa);
    printf("flow_type_rss_offloads=0x%016" PRIx64 "\n",
           info.flow_type_rss_offloads);
}
```

VF 常见限制：

```text
队列数少于 PF
不能随意改 MAC/VLAN，受 PF 策略限制
promiscuous/allmulti 可能需要 trust on
部分 offload 只有 PF 有，VF 没有
rte_flow 能力依赖 PMD、firmware 和 switchdev/eswitch 模式
VF reset 可能受 PF 或 firmware 控制
```

更实用的验证方式：

```bash
sudo dpdk-testpmd -l 0-3 -n 4 -a 0000:3d:00.1 -- -i

testpmd> show port info all
testpmd> show port stats all
testpmd> show port xstats all
testpmd> show port rss-hash 0
testpmd> show port fdir 0
```

## 7. VF 安全边界：MAC、VLAN、spoofchk、trust

### 7.1 spoofchk

```bash
sudo ip link set enp61s0f0 vf 0 mac 00:11:22:33:44:55
sudo ip link set enp61s0f0 vf 0 spoofchk on
```

语义：

```text
spoofchk on:
  NIC/PF 驱动会检查 VF 发出的源 MAC/VLAN 等字段
  不符合 PF 配置的报文可能被丢弃

spoofchk off:
  放宽检查
  适合需要发多 MAC、桥接、转发或某些 DPDK NF 场景
  多租户环境要谨慎
```

### 7.2 trust

```bash
sudo ip link set enp61s0f0 vf 0 trust on
```

`trust on` 通常会给 VF 更多能力，但具体能力依赖驱动。常见影响包括：

```text
允许 VF 请求 promiscuous/allmulti
允许更多 MAC/VLAN/filter 配置
允许某些 offload 或 flow steering 能力
```

不要把 `trust on` 理解成“VF 可以安全地发送任何流量”。它是放权，不是安全增强。

生产建议：

```text
普通租户 VF:
  spoofchk on
  trust off
  固定 MAC/VLAN

受控 DPDK NF / 网关 / 转发器:
  根据需求打开 trust
  必要时关闭 spoofchk
  在上游交换机、ToR 或硬件 ACL 上补安全边界
```

### 7.3 VLAN

```bash
sudo ip link set enp61s0f0 vf 0 vlan 100
```

这通常表示 PF/NIC 为 VF 设置 port VLAN 或 VLAN 过滤/插入策略。不同驱动表现可能不同：

```text
有的会让 VF 收到 untagged 包，硬件负责剥离/插入 VLAN
有的会要求 VF 自己处理 VLAN tag
有的组合会影响 DPDK app 是否还能看到 VLAN header
```

压测或排障时，要同时看：

```bash
ip -d link show enp61s0f0
ethtool -k enp61s0f0
tcpdump / dpdk-dumpcap / testpmd xstats
```

## 8. SR-IOV 与 OVS-DPDK、vhost-user、vDPA 的关系

几条路径的本质不同：

| 路径                    | Guest 看到       | Host 数据面                 | 优点                         | 代价                       |
| ----------------------- | ---------------- | --------------------------- | ---------------------------- | -------------------------- |
| virtio-net + vhost-user | virtio-net       | OVS-DPDK/VPP 处理 virtqueue | 管控灵活，适合云网络         | Host CPU 参与更多          |
| SR-IOV VF passthrough   | 厂商 VF PCI 网卡 | NIC 硬件/embedded switch    | 性能强、延迟低               | 绕过部分 Host vSwitch 能力 |
| vDPA                    | virtio-net       | 硬件理解 virtqueue          | 保留 virtio 语义并卸载数据面 | 依赖硬件/驱动/firmware     |

SR-IOV 和 vhost-user 不是谁替代谁，而是不同取舍：

```text
需要 overlay、安全组、镜像、service chain:
  通常偏 OVS-DPDK/vhost-user/virtio

需要极致性能、路径简单、租户边界可硬件化:
  SR-IOV VF 更直接

希望 Guest 仍用 virtio，但数据面更硬件化:
  看 vDPA
```

## 9. VF representor 和 switchdev

现代智能网卡/高端 NIC 常见一个概念：VF representor。

```text
VF:
  给 VM/Pod/DPDK app 使用的数据面 PCI function

VF representor:
  Host 侧代表这个 VF 的控制/转发表达端口
  OVS/TC/DPDK 可以通过 representor 给 VF 下发流表、统计、镜像或转发策略
```

简化图：

```text
VM VF 0
  |
NIC embedded switch
  |
Host representor port pf0vf0
  |
OVS / TC / DPDK rte_flow
```

这能缓解“SR-IOV 绕过 Host vSwitch，平台看不见流量”的问题。代价是硬件、驱动、
firmware、switchdev/eswitch 模式和 OVS/DPDK 版本都要匹配。

不是所有 SR-IOV 网卡都有 representor，也不是所有 representor 能力都一样。

## 10. 性能判断不要用固定数字

原文里那种固定表格：

```text
virtio-net: 5-10 Gbps
SR-IOV VF: 15-20 Gbps
physical NIC: 40-100 Gbps
```

容易误导。真实性能取决于：

```text
链路速率: 10G/25G/40G/100G/200G/400G
包长: 64B 小包看 Mpps，1500B 大包看 Gbps
PCIe 代际和 lane 数
NUMA locality
VF 队列数和 RSS 配置
Guest vCPU pinning
Host IOMMU 模式
PMD/firmware/offload 能力
是否跨 socket 或跨 root complex
```

更可靠的测试顺序：

```text
1. PF kernel driver 下确认链路和 firmware
2. 创建 VF，先用 Guest kernel driver 或 Host testpmd 验证收发
3. 用 Pktgen back-to-back 建流量源基线
4. 用 testpmd 查看 VF 队列/offload/xstats
5. 再测真实 DUT 或 VM/CNF 路径
```

## 11. 常见问题排查

### 11.1 `sriov_numvfs` 写入失败

检查：

```bash
dmesg | tail -n 100
cat /sys/bus/pci/devices/0000:3d:00.0/sriov_totalvfs
lspci -vv -s 0000:3d:00.0 | grep -i -A20 "Single Root"
```

常见原因：

```text
BIOS 没开 SR-IOV
IOMMU 没开
PF 驱动不支持或 firmware 不支持
请求 VF 数超过 sriov_totalvfs
当前已有 VF 被使用，不能直接改数量
```

### 11.2 VF 绑定 vfio-pci 失败

检查 IOMMU group：

```bash
readlink -f /sys/bus/pci/devices/0000:3d:00.1/iommu_group
ls -l /sys/kernel/iommu_groups/*/devices/
```

如果同一个 group 里还有其他设备，也要一起考虑安全隔离。VFIO 的隔离粒度是 IOMMU
group，不是你肉眼看到的单个 PCI function。

### 11.3 Guest 看不到 VF

检查 Host：

```bash
lspci -nnk -s 0000:3d:00.1
ls -l /dev/vfio/
```

检查 QEMU/libvirt：

```text
是否用了 vfio-pci
是否传了正确 Host BDF
IOMMU group 是否可用
VM 是否启用 IOMMU/PCIe root port 相关配置
```

Guest 内：

```bash
lspci -nn
dmesg | grep -i -E "vfio|iavf|ixgbevf|mlx|bnxt|ena"
```

### 11.4 VF 能收不能发，或发出去被丢

重点查：

```bash
ip -d link show enp61s0f0
ethtool -S enp61s0f0
```

常见原因：

```text
VF MAC 和应用实际源 MAC 不一致
spoofchk on 丢弃了源 MAC/VLAN 不匹配的包
VLAN 策略和 DPDK app 看到的报文格式不一致
trust off 导致 promisc/allmulti/filter 配置失败
DUT 或 ToR 上游没有对应 VLAN/MAC 学习
```

### 11.5 DPDK 能看到端口，但 offload 不工作

不要只看 app 配置，要看 PMD 暴露能力：

```text
testpmd> show port info all
testpmd> show port xstats all
testpmd> show port rss-hash 0
```

可能原因：

```text
VF 不支持这个 offload
PF 没给 VF 开权限
firmware/driver 版本不匹配
trust/switchdev/eswitch 模式不满足
rte_flow 规则实际下发失败
```

## 12. 云环境里怎么理解 SR-IOV

公有云里不要套用裸金属 Host 的管理方式。你通常拿不到 PF，也不能在 Guest 里创建 VF：

```text
裸金属/自建虚拟化:
  你管理 PF
  你 echo sriov_numvfs
  你配置 VF MAC/VLAN/trust/spoofchk
  你把 VF 分给 VM/Pod

公有云 VM:
  云厂商管理 PF 和 VF
  Guest 里只看到已经分配好的虚拟网卡或加速网卡
  你不能假设能写 sriov_numvfs
```

AWS、Azure、GCP 都有自己的虚拟网卡模型和加速网络实现。对使用者来说，更务实的检查方式是：

```bash
lspci -nn
ethtool -i eth0
ethtool -S eth0
```

不要在文章里写“某云一定要求 trust on”这类裸金属 Host 命令。云上的 trust/spoofchk/VLAN
通常由云平台控制，不是租户 VM 自己设置。

## 13. 操作清单

裸金属 Host 上准备 VF：

```text
1. BIOS 打开 IOMMU/SR-IOV
2. 内核打开 intel_iommu=on 或 amd_iommu=on
3. PF 使用支持 SR-IOV 的 kernel driver
4. 查看 sriov_totalvfs
5. 写 sriov_numvfs 创建 VF
6. 用 ip link 配置 VF MAC/VLAN/rate/spoofchk/trust
7. 根据场景绑定 VF:
   - kernel driver: 给普通 Host/Pod netdevice
   - vfio-pci: 给 VM 或 DPDK app
8. 用 lspci、dpdk-devbind.py、testpmd、ethtool/xstats 验证
```

DPDK 使用 VF 前确认：

```text
VF 所在 NUMA node
IOMMU group 是否干净
hugepage 是否足够
VF 是否绑定 vfio-pci
队列数和 RSS 是否满足需求
PF 侧 trust/spoofchk/VLAN 是否和应用行为一致
```

## 14. 总结

SR-IOV 的核心不是“魔法直通”，而是：

```text
PF 管控制面
VF 承担数据面
VFIO/IOMMU 负责安全分配
PF driver/firmware 决定 VF 权限
DPDK app 通过 PMD 驱动 VF
```

真正排障时，要同时看三层：

```text
PCI/VFIO:
  BDF、driver、IOMMU group、/dev/vfio

PF policy:
  MAC、VLAN、trust、spoofchk、rate、representor

DPDK datapath:
  queues、RSS、offload、xstats、NUMA、mbuf/IOVA
```

这三层都对上，SR-IOV 才会表现出它应有的低延迟和高吞吐。

---

## 参考资源

- [Linux Kernel PCI Express I/O Virtualization Howto](https://docs.kernel.org/PCI/pci-iov-howto.html)
- [Linux Kernel VFIO Documentation](https://docs.kernel.org/driver-api/vfio.html)
- [DPDK Intel Virtual Function Driver](https://doc.dpdk.org/guides/nics/intel_vf.html)
- [DPDK Linux Drivers Guide](https://doc.dpdk.org/guides/linux_gsg/linux_drivers.html)
- [SR-IOV Network Device Plugin for Kubernetes](https://github.com/k8snetworkplumbingwg/sriov-network-device-plugin)
