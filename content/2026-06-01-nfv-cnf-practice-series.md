---
title: "NFV/CNF 实战系列：从 OVS-DPDK+vhost-user 到 VPP+memif 的一站式实践"
date: 2026-06-01 09:00:00
tags: [nfv, cnf, dpdk, ovs-dpdk, vhost-user, vpp, memif, qemu, virtio, hands-on, lab]
description: "用两个完整可复现的实验把 NFV 数据通路（OVS-DPDK + QEMU + Guest DPDK）和 CNF 数据通路（VPP + memif）从环境、步骤、测试到排错串起来。"
---

# NFV/CNF 实战系列：从 OVS-DPDK+vhost-user 到 VPP+memif 的一站式实践

> [!info] 本系列目标
> 这是一份“打开就能跑”的实战文档，配合仓库里的两个实践目录：
>
> - `practice/guest_dpdk_virtio/` —— **NFV 数据通路**：Host OVS-DPDK → vhost-user → QEMU → Guest DPDK
> - `practice/cnf_multus_demo/` —— **CNF 数据通路**：Linux 转发 → VPP+AF_PACKET → VPP+memif
>
> 上层概念（NFV/VNF/CNF 商业逻辑、vhost-user 协议、memif 实现）在
> [[2026-05-26-nfv-network-functions-virtualization|NFV 深入理解]] 和
> [[2026-05-26-vpp-deep-dive-ch19a-memif|VPP memif 深入探讨]] 里讲过，这里只讲“怎么做”。

## 0. 全文导览

```text
第一部分  环境与依赖
  1. 硬件要求
  2. 操作系统与基础包
  3. 通用准备（hugepage / 内核模块 / 权限）

第二部分  NFV 实战：OVS-DPDK + vhost-user + Guest DPDK
  4. 拓扑与角色分工
  5. 一步一步搭建（手工模式）
  6. 自动化一条命令模式
  7. 测试方法与预期结果
  8. 清理

第三部分  CNF 实战：VPP + memif 三级数据通路
  9. 拓扑与三级数据通路对比
  10. Tier 0  内核 baseline
  11. Tier 1  VPP + AF_PACKET
  12. Tier 2  VPP + memif
  13. 清理

第四部分  排错与性能
  14. 常见问题与根因
  15. 性能对照与何时选哪条路
```

---

# 第一部分　环境与依赖

## 1. 硬件要求

| 资源                   | 最低                     | 推荐                         | 用途                                                 |
| ---------------------- | ------------------------ | ---------------------------- | ---------------------------------------------------- |
| CPU 架构               | x86_64 with VT-x / AMD-V | 同上 + IOMMU (VT-d / AMD-Vi) | KVM 嵌套、VFIO、vhost                                |
| 物理核数               | 4                        | 8+                           | QEMU 2 vCPU + OVS-DPDK + VPP 各自独占核              |
| 内存                   | 8 GB                     | 16 GB+                       | Guest 1 GB + Host DPDK 1 GB + 系统                   |
| 巨页（Hugepage 2 MiB） | 2048 页（≈4 GiB）        | 4096 页                      | OVS-DPDK、QEMU、VPP 都依赖                           |
| 网卡                   | 任意                     | 多队列 + 至少 10 GbE         | 真生产里 vhost 落到物理口；本实验用内部 OVS 端口即可 |
| 虚拟化支持             | BIOS 打开 VT-x / VT-d    | 同上                         | 否则 QEMU `-enable-kvm` 会失败                       |

> [!warning] Fedora / RHEL 注意
> 默认 SELinux 处于 enforcing 时，容器挂载 `hugetlbfs` 会被拒绝。本实验脚本遇到这种情况会
> 提示切到 permissive（`sudo setenforce 0`），或更稳的方式是在 `/etc/selinux/config` 长期配置。
> Ubuntu 几乎不会遇到这个问题。

## 2. 操作系统与基础包

> 本文档在 **Fedora 43** 上完整跑通；Ubuntu/Debian 在包名和 systemd 单元上有差异，思路一致。

```bash
# Fedora
sudo dnf install -y \
  openvswitch-dpdk \
  dpdk dpdk-tools \
  qemu-kvm qemu-img \
  genisoimage cloud-utils-growpart cloud-utils-cloud-localds \
  pciutils ethtool \
  podman \
  ansible-core      # 可选，用于 guest image 自动化
```

| 包                                        | 在哪个实验里用到 | 备注                                           |
| ----------------------------------------- | ---------------- | ---------------------------------------------- |
| `openvswitch-dpdk`                        | NFV 主机         | 提供 `ovs-vsctl` + DPDK 加速的 `ovs-vswitchd`  |
| `dpdk / dpdk-tools`                       | 主机 + 客户机    | `dpdk-devbind.py` 用来把 PCI 设备绑到 UIO/VFIO |
| `qemu-kvm / qemu-img`                     | NFV              | 启动 guest                                     |
| `genisoimage / cloud-utils-cloud-localds` | NFV              | 制作 cloud-init seed ISO                       |
| `pciutils`                                | 双方             | `lspci` 确认设备                               |
| `podman`                                  | CNF              | 跑 VPP 容器（docker 也可以）                   |
| `ansible-core`                            | NFV（可选）      | `ansible/guest_image.yml` 自动准备 cloud image |

启动 OVS 服务：

```bash
sudo systemctl enable --now openvswitch
sudo systemctl status ovs-vswitchd
```

## 3. 通用准备：Hugepage、内核模块、用户组

hugepage 是 **所有** userspace fast path（OVS-DPDK、DPDK 原生应用、VPP memif）的底座。
hugepage 不能被 swap，而且需要在系统启动前预留，否则运行中临时分配会失败。

```bash
# 预留 2 GiB 巨页（NFV 实验 1024 页起，CNF 容器 256 页起）
echo 1024 | sudo tee /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 挂载 hugetlbfs（Fedora 一般已自动挂载到 /dev/hugepages）
mount | grep huge

# 创建 hugetlbfs 用户组（OVS-DPDK 守护进程使用）
sudo groupadd -f hugetlbfs
sudo usermod -aG hugetlbfs "$USER"   # 让 OVS-DPDK 进程组能访问
```

确认效果：

```bash
$ grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo
HugePages_Total:    1024
HugePages_Free:     1024
Hugepagesize:       2048 kB
```

DPDK 驱动加载（NFV 客户机里要把 virtio-net PCI 设备绑到 DPDK 驱动）：

```bash
# uio_pci_generic: 内置在主线内核，多数发行版免安装
sudo modprobe uio
sudo modprobe uio_pci_generic

# vfio-pci: 更现代，支持 IOMMU 隔离
sudo modprobe vfio vfio-pci
```

> [!tip] `uio_pci_generic` vs `vfio-pci`
>
> - 简单实验用 `uio_pci_generic` 就够，兼容性最好。
> - 生产环境用 `vfio-pci`：可以做 IOMMU 隔离、配合 `vfio-iommu` 防止恶意 guest DMA 越界。
> - 切换：`dpdk-devbind.py -b vfio-pci 0000:00:03.0`

---

# 第二部分　NFV 实战：OVS-DPDK + vhost-user + Guest DPDK

> 本节对应 `practice/guest_dpdk_virtio/`，完整源码在那个目录里。
> 下面的步骤既可以拆开手敲，也可以直接用 `run_host_lab.sh` 一条命令跑。

## 4. 拓扑与角色分工

```text
┌──────────────────────────────────────────────────────────────────────┐
│ Host                                                                 │
│                                                                      │
│  OVS-DPDK                                                            │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ br-dpdk                                                      │    │
│  │   vhost-user0  <──── Unix socket ────>  QEMU virtio-net      │    │
│  │   host-traffic0  (internal port, 198.18.0.1/24)              │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                      │
│  QEMU/KVM                                                            │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │ virtio-net-pci (guest 端)                                     │    │
│  │ memory backend: hugetlbfs, share=on, prealloc=on              │    │
│  │ management: user-mode nic + 127.0.0.1:10022 → guest :22       │    │
│  └──────────────────────────────────────────────────────────────┘    │
└───────────────────────────────┬──────────────────────────────────────┘
                                │ virtqueue 在 guest 内存
                                ▼
┌──────────────────────────────────────────────────────────────────────┐
│ Guest VM                                                              │
│                                                                      │
│  dpdk-testpmd                                                         │
│    → DPDK virtio PMD                                                  │
│    → virtio-net PCI 设备（绕过 guest 内核协议栈）                       │
└──────────────────────────────────────────────────────────────────────┘
```

各角色在数据通路里的位置：

| 角色             | 拥有什么                                          | 不参与什么                   |
| ---------------- | ------------------------------------------------- | ---------------------------- |
| Host OVS-DPDK    | vhost-user socket 客户端、转发 datapath           | 不碰 guest 内存，只搬运 mbuf |
| QEMU/KVM         | 创建设备、搬运 guest 内存布局、eventfd 通知       | 不解析 packet                |
| Guest virtio PMD | 直接读写 virtqueue 内存、收发包                   | 不走 Linux 内核网络栈        |
| Guest testpmd    | 把收到的包从 RX 队列搬到 TX 队列（`io` 转发模式） | 不改包内容                   |

## 5. 一步一步搭建（手工模式）

下面这段在主机里执行。**全部需要 root**。

### 5.1 装包

```bash
sudo dnf install -y openvswitch-dpdk dpdk dpdk-tools qemu-kvm qemu-img \
  genisoimage cloud-utils-cloud-localds pciutils
sudo systemctl enable --now openvswitch
```

### 5.2 准备 hugepage

```bash
sudo ./host/01_setup_hugepages.sh
# 等价于：
#   echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
#   mount -t hugetlbfs -o pagesize=2M,mode=1770,gid=<hugetlbfs gid> /dev/hugepages
```

### 5.3 配置 OVS-DPDK 桥和 vhost-user 端口

```bash
sudo ./host/02_setup_ovs_dpdk_vhost_user.sh
```

该脚本会做四件事：

```text
1. ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
2. ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem=512   # 单 NUMA
3. ovs-vsctl set Open_vSwitch . other_config:dpdk-hugepage-dir=/dev/hugepages
4. systemctl restart ovs-vswitchd
5. ovs-vsctl add-br br-dpdk -- set bridge br-dpdk datapath_type=netdev
6. ovs-vsctl add-port br-dpdk vhost-user0 \
       -- set Interface vhost-user0 type=dpdkvhostuserclient \
          options:vhost-server-path=/var/run/openvswitch/vhost-user0.sock \
          options:vhost-client-reconnect-interval=1000
```

`dpdkvhostuserclient` 的含义：OVS-DPDK **主动连** QEMU 创建的 server socket；如果 QEMU 还没起，
OVS 会一直重试（`reconnect-interval=1000ms`），这就是“QEMU 先起也能跑”的原因。

### 5.4 给 OVS 加一个 internal 测试口

```bash
sudo ./host/03_setup_test_traffic_port.sh
# 创建 host-traffic0 (type=internal) 加到 br-dpdk，配置 198.18.0.1/24
```

> `host-traffic0` 是 OVS 内部的 Linux 接口，从这里发包 = 从 OVS datapath 发包，
> 是后面验证 vhost-user 数据通路的“探针”。

### 5.5 启动 QEMU 客户机

```bash
sudo GUEST_IMAGE=/path/to/dpdk-guest.qcow2 \
     ./qemu/start_guest_vhost_user.sh
```

关键参数说明：

| 参数                                                                                     | 作用                                                                               |
| ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `-enable-kvm`                                                                            | 必须，否则性能不可用                                                               |
| `-cpu host`                                                                              | 暴露宿主 CPU 特性，方便 DPDK 探测                                                  |
| `-object memory-backend-file,id=mem0,...,mem-path=/dev/hugepages,share=on,prealloc=on`   | 用 hugetlbfs 共享内存作为客户机 RAM；`share=on` 是 vhost-user 看到同一段内存的前提 |
| `-chardev socket,id=char0,path=/var/run/openvswitch/vhost-user0.sock,server=on,wait=off` | 创建 vhost-user server socket，让 OVS-DPDK 主动连                                  |
| `-netdev type=vhost-user,id=net0,chardev=char0,vhostforce=on,queues=1`                   | QEMU 把 vhost-user socket 包装成网卡；`vhostforce=on` 表示强制使用 vhost 协议      |
| `-device virtio-net-pci,netdev=net0,mac=52:54:00:12:34:56,mq=on,vectors=4`               | 创建客户机里的 virtio-net PCI 设备；`vectors=2*queues+2` 给 MSI-X 中断向量         |
| `-netdev user,id=mgmt0,hostfwd=tcp:127.0.0.1:10022-:22`                                  | 额外的管理口，用 SLIRP 模式走 SSH                                                  |

> [!warning] vhost-user socket 文件权限
> QEMU 以 root 启动会创建 socket，但 OVS-DPDK 在 Fedora 上以 `openvswitch:hugetlbfs` 用户运行。
> 脚本里 `umask 000` 是关键，没有它会出现 `connection refused`。

### 5.6 客户机内：装 DPDK、绑设备、跑 testpmd

ssh 进 guest（默认 10022 端口）后：

```bash
# 1. 准备客户机 hugepage（guest 内）
sudo ./guest/01_setup_hugepages.sh

# 2. 把 virtio-net PCI 设备绑到 DPDK 驱动
sudo ./guest/02_bind_virtio_to_vfio.sh 0000:00:03.0
# 0000:00:03.0 是这个实验里 -device virtio-net-pci 暴露给客户机的 BDF
# 如果不确定，先 lspci | grep -i virtio，或者在主机用 dpdk-devbind.py -s 看

# 3. 启动 testpmd
sudo ./guest/03_run_testpmd.sh
# 进入交互模式，常用命令：
#   show port info all
#   set fwd io           # io 模式 = 收到就发回，不改包
#   start
#   show port stats all
```

## 6. 自动化一条命令模式

如果不想手工一步步跑，用 `run_host_lab.sh` 把上面 5.2–5.6 全串起来：

```bash
cd practice/guest_dpdk_virtio

# 全自动：装包 + 准备 cloud image + 跑 host lab + 自动跑 guest smoke test
sudo AUTO_PREPARE_GUEST=1 ./run_host_lab.sh

# 想跑大点：
sudo AUTO_PREPARE_GUEST=1 MEM_SIZE=2048M SMP=4 QEMU_CPUSET=4-7 ./run_host_lab.sh

# 想跑完保留 VM 继续玩：
sudo AUTO_PREPARE_GUEST=1 KEEP_VM_AFTER_RUN=1 ./run_host_lab.sh

# 想跳过自动装包（你已经装好了）：
sudo AUTO_INSTALL_DEPS=0 AUTO_PREPARE_GUEST=1 ./run_host_lab.sh
```

脚本运行时会做四件关键事：

```text
1. 装包（如果 AUTO_INSTALL_DEPS=1）
2. 用 Ansible 拉 cloud image + 写 cloud-init + 重生 seed ISO
3. 跑 host lab（hugepage / OVS-DPDK / traffic port / QEMU / guest smoke）
4. 自动清理
```

跑完后 `generated/qemu-env.sh` 会保存环境变量，下次再跑直接 `source` 它就够。

## 7. 测试方法与预期结果

### 7.1 客户机内：看 testpmd 端口统计

在 guest 的 testpmd 里：

```text
testpmd> show port info all

# 期望看到 Port 0 是 1 个 RxQ + 1 个 TxQ，MAC 是 52:54:00:12:34:56
testpmd> set fwd io
testpmd> start
testpmd> show port stats all

# RX-packets: 256   TX-packets: 256   （取决于 host 发了多少）
```

### 7.2 主机：从 host-traffic0 发包验证端到端

在主机里跑：

```bash
sudo python3 ./host/04_send_test_traffic.py
# 默认发 256 帧，间隔 5 ms，0x88B5 以太类型，广播 MAC
```

回到 guest testpmd，应当看到：

```text
  RX-packets: 256    TX-packets: 256    RX-errors: 0
```

> [!note] 0x88B5 是什么
> 这是 IEEE 保留的 “Local Experimental Ethertype”，随便选一个不冲突的就行。
> 如果你想跑真正的 L3 测试，把目的 MAC 改成 guest 的 MAC，EtherType 改成 0x0800，
> 在 testpmd 里 `set fwd mac` 即可。

### 7.3 主机：检查 OVS 端统计

```bash
ovs-ofctl dump-ports br-dpdk
# 看 vhost-user0 端口的 rx_packets / tx_packets 是否同步增长
```

## 8. 清理

```bash
cd practice/guest_dpdk_virtio
sudo ./cleanup_host_lab.sh

# 想顺带把生成的 cloud image / seed ISO 一起删掉：
sudo REMOVE_GENERATED=1 REMOVE_HUGEPAGE_MOUNT=1 ./cleanup_host_lab.sh
```

清理脚本会做：

```text
1. 停 QEMU（按 pidfile + pgrep 双保险）
2. ovs-vsctl del-port / del-br
3. 清掉 dpdk-init / dpdk-socket-mem / dpdk-hugepage-dir
4. 删除 traffic port IP
5. 删除 vhost-user socket
6. 把 hugepage 归零（nr_hugepages=0）
7. （可选）卸载 /dev/hugepages、删 generated/
```

---

# 第三部分　CNF 实战：VPP + memif 三级数据通路

> 本节对应 `practice/cnf_multus_demo/`，核心是 **同一个拓扑，
> 三种完全不同的转发实现**。每跑通一级都能直接看到性能差距。

## 9. 拓扑与三级数据通路对比

```text
  App NS  ←──────→  CNF NS  ←──────→  WAN NS
            veth 1                veth 2
   10.10.1.2        10.10.1.1 / 10.10.2.1        10.10.2.2
```

| Tier | 转发器                    | 报文路径                                                       | context switch     | 数据拷贝                       | 典型延迟   |
| ---- | ------------------------- | -------------------------------------------------------------- | ------------------ | ------------------------------ | ---------- |
| 0    | Linux 内核 `ip_forward=1` | `app → veth → 内核 → veth → wan`                               | 每跳 ≥1 次 syscall | 每跳 ≥1 次拷贝                 | 1–5 μs     |
| 1    | VPP + AF_PACKET           | `app → veth → AF_PACKET → VPP 节点图 → AF_PACKET → veth → wan` | 0 syscall          | 0 copy（AF_PACKET 会从内核拿） | 0.5–1 μs   |
| 2    | VPP + memif               | `vpp-app → memif ring → vpp-cnf → memif ring → vpp-wan`        | 0 syscall          | 0 copy（共享内存）             | 100–300 ns |

## 10. Tier 0　Linux 内核 baseline

```bash
cd practice/cnf_multus_demo
sudo ./01_setup_ns.sh
sudo ./02_test_linux.sh
```

`01_setup_ns.sh` 干了什么：

```text
1. 创建 3 个 netns: app / cnf / wan
2. 创建 2 对 veth：app-net1 ↔ cnf-in，cnf-out ↔ wan-net1
3. 配置 IP + 路由
4. 在 cnf 里 sysctl -w net.ipv4.ip_forward=1
```

`02_test_linux.sh` 里就是从 app ping 10.10.2.2，应该 0% 丢包。
这是 baseline，所有 Tier 1/Tier 2 都基于这个拓扑改。

## 11. Tier 1　VPP + AF_PACKET

```bash
sudo ./03_setup_vpp.sh
sudo ./04_test_vpp.sh
```

`03_setup_vpp.sh` 关键步骤：

```text
1. 在 cnf ns 里 sysctl -w net.ipv4.ip_forward=0   (让 VPP 接管)
2. ip netns exec cnf ip addr flush dev cnf-in     (让 VPP 拥有 ARP/NDP)
   ip netns exec cnf ip addr flush dev cnf-out
3. 写 /tmp/cnf_vpp.conf（禁用 dpdk_plugin.so 避免与 AF_PACKET 冲突）
4. podman run --privileged --network ns:/var/run/netns/cnf 跑 vpp
5. 容器里 create host-interface name cnf-in / cnf-out 并配 IP
```

`04_test_vpp.sh` 验证：

```text
1. vppctl show interface          看到 host-cnf-in / host-cnf-out
2. vppctl show ip fib             看到 10.10.1.0/24 / 10.10.2.0/24
3. vppctl show ip neighbor        ARP 表里有 app 和 wan
4. ping 10.10.1.1 一次（热身 ARP）然后 ping 10.10.2.2 五次
5. vppctl show runtime            看 ethernet-input / ip4-input / ip4-lookup 包数
```

> [!warning] VPP 容器里必须 `--entrypoint ""` 启动
> 多数 VPP 镜像（`travelping/vpp` 等）的默认 entrypoint 是 `sh -c /usr/bin/vpp`，
> 它会吃掉你传的 `-c /tmp/...conf` 参数，导致容器秒退 0 退出码。
> 脚本里用 `--entrypoint "" /usr/bin/vpp -c /tmp/...conf` 直接调 vpp 主程序。
> 本文实验用 `docker.io/calicovpp/vpp:latest`（VPP v26.06），
> gtpu_plugin 稳定、memif 实现成熟。

## 12. Tier 2　VPP + memif

```bash
sudo ./05_setup_memif.sh
sudo ./06_test_memif.sh
```

`05_setup_memif.sh` 把 veth 全部 down 掉，启 3 个 VPP 容器：

```text
vpp-app   在 app ns
vpp-cnf   在 cnf ns
vpp-wan   在 wan ns
```

3 个容器共享同一份 `-v /tmp:/tmp`，memif socket 文件落在 `/tmp/memif/`。

memif 接口创建是 **两步**（VPP v26.06+）：

```bash
# 1. 先建 socket
vppctl create memif socket id 1 filename /tmp/memif/app_cnf.sock

# 2. 再建接口，引用 socket id
vppctl create interface memif id 1 master socket-id 1   # app 侧
vppctl create interface memif id 1 slave  socket-id 1   # cnf 侧
```

master / slave 是角色，不是性能差别：master 创建 socket 文件，slave 连过去。
生产里通常让数据流的 “上游” 当 master，便于控制连接时序。

配 IP + 路由（注意：VPP v26.06 默认开启 **uRPF** unicast reverse path filter，
每个 VPP 都要有回去的路由，否则 ICMP 会被默默丢弃）：

```bash
# app
set interface state memif1/1 up
set interface ip address memif1/1 10.10.1.2/24
ip route add 10.10.2.0/24 via 10.10.1.1

# cnf
set interface state memif1/1 up
set interface ip address memif1/1 10.10.1.1/24
set interface state memif2/2 up
set interface ip address memif2/2 10.10.2.1/24

# wan
set interface state memif2/2 up
set interface ip address memif2/2 10.10.2.2/24
ip route add 10.10.1.0/24 via 10.10.2.1
```

`06_test_memif.sh` 验证：

```text
1. vppctl show interface        看到 memif1/1 / memif2/2，状态 up
2. vppctl show memif            看到 role=master/slave, socket 路径, ring 统计
3. vpp-app ping 10.10.1.1       通
4. vpp-app ping 10.10.2.2       通（穿过 vpp-cnf 的两次 memif 转发）
5. vppctl show runtime          看 memif-input / ip4-lookup 节点包数
```

## 13. 清理

```bash
cd practice/cnf_multus_demo
sudo ./99_cleanup.sh
```

会做：

```text
1. podman rm -f vpp-app vpp-cnf vpp-wan cnf-vpp
2. ip netns delete app / cnf / wan
3. rm -f /tmp/cnf_vpp.* /tmp/vpp_*.conf /tmp/vpp_*.sock
4. rm -rf /tmp/memif
```

---

# 第四部分　排错与性能

## 14. 常见问题与根因

| 症状                                                               | 直接原因                                      | 真正根因                                     | 修复                                                                                 |
| ------------------------------------------------------------------ | --------------------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------ | -------------------------- | --- | ----- |
| QEMU 启动失败：`failed to initialize hugepage`                     | `/dev/hugepages` 没挂或权限不够               | hugetlbfs 挂载选项里没 `gid=<hugetlbfs gid>` | `mount -o remount,gid=<gid> /dev/hugepages` 或确认 OVS 用户在 hugetlbfs 组           |
| QEMU 启动失败：`vhost-user socket: connection refused`             | OVS 端 socket 不存在                          | OVS 没启 DPDK init 或 socket 路径错          | 检查 `ovs-vsctl get Open_vSwitch . other_config:dpdk-init` 必须 `true`；路径两边一致 |
| QEMU 启动后 OVS 日志报 `vhost-user: failed to connect`             | QEMU 退出时没清 socket 文件                   | 上次残留                                     | `rm -f /var/run/openvswitch/vhost-user*.sock` 再启                                   |
| `dpdk-devbind.py -b uio_pci_generic …` 失败：找不到模块            | 内核没编 `uio_pci_generic`                    | 发行版裁剪了                                 | `apt install linux-modules-extra-$(uname -r)`，或换 `vfio-pci`                       |
| Guest 内 testpmd 起不来：`EAL: no hugepages`                       | Guest 内没预留 hugepage                       | 没跑 `01_setup_hugepages.sh`                 | 在 guest 里跑一遍                                                                    |
| Guest 内 testpmd 起不来：`EAL: cannot find PCI device`             | 设备没绑到 DPDK 驱动                          | 漏跑 `02_bind_virtio_to_vfio.sh`             | 跑绑设备脚本                                                                         |
| VPP 容器秒退 0 退出码                                              | entrypoint 吞参数                             | 镜像默认 entrypoint 行为                     | `--entrypoint ""` + 显式 `/usr/bin/vpp -c ...`                                       |
| VPP 容器秒退 `SIGSEGV: more than one node named 'ip6-gtpu-bypass'` | 启用了 `gtpu_plugin.so`                       | VPP v18.01 旧版 bug                          | 升级到 VPP v26.06+，或配置里 `plugin gtpu_plugin.so { disable }`                     |
| VPP 容器 stderr：`couldn't open log '/run/vpp/vpp.log'`            | 配置里写了 `log` / `pidfile`                  | 容器内 `/run/vpp/` 不存在                    | 配置里去掉 `log` 和 `pidfile` 行                                                     |
| VPP CLI `vppctl` 报 `connection refused`                           | sock 文件路径错                               | 容器里 -v 没挂 `/tmp`                        | 启动容器时 `-v /tmp:/tmp`，`-s` 参数用绝对路径                                       |
| 跑 vppctl 命令批量发，脚本 exit 141                                | SIGPIPE                                       | `set -e` + `echo                             | vppctl`                                                                              | 给所有 vpp_cmd helper 加 ` |     | true` |
| Tier 1 ping 100% 丢包                                              | Linux 还持有 cnf-in/cnf-out 的 IP，吞了 ARP   | Linux 内核仍然做 L3                          | `ip addr flush dev cnf-in` + `sysctl ip_forward=0`                                   |
| Tier 1 ping 偶尔第一个包丢                                         | 第一次需要 ARP 解析                           | 冷启动 ARP 慢                                | 测试脚本先 `ping 10.10.1.1` 热身再发 5 个 ping                                       |
| Tier 2 memif 创建 `Invalid argument`                               | 直接 `create interface memif`                 | VPP v26.06 改成两步                          | 先 `create memif socket id N`，再 `create interface memif id N socket-id N`          |
| Tier 2 app ping 不到 wan 报 `ip4 source lookup miss`               | wan VPP 没收返回路由                          | uRPF 默认开启                                | 给 wan 加 `ip route add 10.10.1.0/24 via 10.10.2.1`                                  |
| Tier 2 memif 接口 stuck down                                       | 配置脚本 SIGPIPE 截断了 `set interface state` | `set -e` 提前退出                            | 单独再发一次 `set interface state memif2/2 up`                                       |
| OVS-DPDK 重启失败                                                  | selinux 拦截 hugepage 访问                    | 容器/服务无 hugetlbfs 权限                   | `sudo setenforce 0` 或写策略                                                         |

### 排错三件套

```bash
# 1. 看 OVS 日志（绝大多数问题都先看这里）
journalctl -u ovs-vswitchd -n 200 --no-pager
tail -f /var/log/openvswitch/ovs-vswitchd.log

# 2. 看 VPP 日志
podman logs cnf-vpp       # Tier 1
podman logs vpp-cnf       # Tier 2

# 3. 看 device 绑定
dpdk-devbind.py -s         # 主机或客户机都行
lspci -vvs <BDF>           # 看 kernel driver / iommu group
```

## 15. 性能对照与何时选哪条路

| 场景                                       | 推荐方案                       | 原因                                                   |
| ------------------------------------------ | ------------------------------ | ------------------------------------------------------ |
| 多 VM 共享一台物理机，每 VM 跑一个 VNF     | **NFV：OVS-DPDK + vhost-user** | vhost-user 跨 VM 边界零拷贝，OVS-DPDK 兼容多厂商生态   |
| 同一节点内多容器（sidecar、链式 NF）       | **CNF：VPP + memif**           | memif 比 vhost-user 更轻、延迟更低；VPP 直接和容器对等 |
| 跨节点容器                                 | K8s Multus + SR-IOV VF         | 物理 NIC 还是要走 PMD                                  |
| 单容器试水                                 | VPP + AF_PACKET                | 不需要绑网卡、不需要 hugepage 配置                     |
| 设备复用（同一设备被 VNF 和 Linux 都要用） | 内核 + tc / OVS-kernel         | userspace fast path 必须独占设备                       |

> [!tip] 怎么判断“卡在哪里”
> 在每条数据通路里都做这几件事，效果立现：
>
> 1. `iperf3 -s` 跑 TCP throughput，对比 Tier 0/1/2
> 2. `pktgen-dpdk` 单包 64 B 测 pps
> 3. `perf stat -e cache-misses,context-switches <cmd>` 看 cache miss 率和上下文切换
>
> memif 跨进程零拷贝，理论 pps 比 AF_PACKET 高一个数量级，
> 但前提是 cache line 隔离做对（生产 VPP 自动处理）。

## 16. 下一步可以往哪里走

- 把 memif 接到真实物理 NIC：在 vpp-cnf 上 `set interface state TenGigabitEthernet0/0/0 up` + `ip route add …`，把 `host-traffic0` 那侧换成 SR-IOV VF。
- 把 NFV 实验的 QEMU guest 换成 VPP guest：guest 跑 VPP+virtio PMD，主机侧 OVS-DPDK 仍然跑 vhost-user 客户端，效果和 testpmd 一样。
- 跑多队列：`-netdev …,queues=4` + `-device …,mq=on,vectors=10`，测试多 RSS 队列下吞吐和乱序情况。
- 接 vDPA：把 virtio-net-pci 设备模拟成物理 PCI 设备，QEMU 通过 vfio-pci 暴露给 guest，完全去掉 vhost-user。
- 接 DPU：把 vhost-user 客户端放到 BlueField-2/3 ARM DPU 上跑，主机 CPU 几乎不参与数据面。

> [!info] 对应仓库内容
>
> - 概念层：[[2026-05-26-nfv-network-functions-virtualization|NFV 深入理解]]、[[2026-05-26-vpp-deep-dive-ch19a-memif|VPP memif 深入探讨]]
> - 协议细节：`content/2026-04-09-dpdk-deep-dive-ch16-vhost-user.md` 等 ch16/ch25/ch26 系列
> - 实践代码：`practice/guest_dpdk_virtio/`、`practice/cnf_multus_demo/`
