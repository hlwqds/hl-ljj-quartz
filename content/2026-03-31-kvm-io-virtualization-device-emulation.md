---
title: KVM I/O 虚拟化深度解析：MMIO/PIO Trap、QEMU 设备模拟与 virtio/vhost 加速
date: 2026-03-31
tags: [virtualization, kvm, qemu, io-virtualization, mmio, pio, virtio, vhost, vfio]
---

> [!abstract] 核心概述
> I/O 虚拟化回答的问题是：Guest 访问"硬件设备"时，Host 如何接管、模拟或加速这个访问。
>
> - **PIO 捕获**：x86 `in/out` 端口访问通过 I/O bitmap 触发 VM-Exit。
> - **MMIO 捕获**：设备地址不映射为普通 RAM，Guest 访问时触发 EPT/NPT violation。
> - **QEMU 设备模型**：KVM 处理不了的复杂 I/O 退出会交给 QEMU，由 QEMU 模拟设备寄存器、DMA 和中断。
> - **virtio/vhost 加速**：用共享内存 virtqueue + eventfd 减少传统设备模拟的 VM-Exit 和拷贝开销。
> - **VFIO/SR-IOV 直通**：绕过软件设备模拟，让 Guest 直接驱动真实设备或 VF。

---

# KVM I/O 虚拟化深度解析：MMIO/PIO Trap、QEMU 设备模拟与 virtio/vhost 加速

CPU 虚拟化解决的是"Guest 指令如何在物理 CPU 上运行"；内存虚拟化解决的是
"Guest physical address 如何映射到 Host physical address"。

I/O 虚拟化解决的是另一个问题：

```text
Guest 以为自己在访问网卡、磁盘、串口、PCI 设备；
Host 如何接管这些访问，并把它们转成真实硬件或软件后端操作？
```

---

## 一、 为什么 I/O 不能完全直接执行

普通计算指令可以直接在物理 CPU 上运行：

```text
ADD / MOV / JMP / CMP
```

但 I/O 指令或设备寄存器访问不能随便让 Guest 直接执行，因为它们会影响全局硬件状态：

```text
写真实网卡寄存器
改真实中断控制器
访问真实磁盘控制器
发起真实 DMA
```

因此 KVM 的策略是：

```text
普通指令：直接运行
敏感 I/O：VM-Exit 到 Host，由 KVM/QEMU 模拟或转发
```

整体路径：

```text
Guest Driver
  -> PIO / MMIO / DMA descriptor
  -> VM-Exit 或共享队列通知
  -> KVM
  -> QEMU / vhost / VFIO
  -> Host kernel / DPDK / real device
```

---

## 二、 PIO 捕获：I/O Bitmap 拦截 in/out

PIO (Port I/O) 是 x86 传统 I/O 方式，使用 `in` / `out` 指令访问端口：

```asm
out 0x3f8, al   ; 写串口端口
in  al, 0x60    ; 读键盘控制器端口
```

KVM 运行 vCPU 前，会在 VMCS/VMCB 中配置 I/O bitmap。这个 bitmap 告诉 CPU：

```text
哪些 I/O port 允许 Guest 直接访问
哪些 I/O port 必须触发 VM-Exit
```

PIO 捕获流程：

```text
Guest 执行 out 0x3f8, al
        │
        ▼
CPU 查 I/O bitmap
        │
        ▼
发现该 port 需要拦截
        │
        ▼
VM-Exit 到 KVM
        │
        ▼
KVM 生成 KVM_EXIT_IO
        │
        ▼
QEMU 收到退出原因
        │
        ▼
QEMU 找到对应设备模型
        │
        ▼
调用 serial_ioport_write() / pci_config_write() 等回调
        │
        ▼
KVM_RUN 恢复 Guest
```

可以把 PIO 理解成：

```text
Guest 对端口的 in/out，被 CPU 硬件根据 I/O bitmap 拦截。
```

---

## 三、 MMIO 捕获：EPT/NPT 不映射设备地址

MMIO (Memory-Mapped I/O) 看起来像普通内存访问：

```c
*(volatile uint32_t *)0xfebc0000 = value;
```

但这个地址不是 RAM，而是设备寄存器地址。例如 PCI BAR 映射出来的网卡寄存器。

关键点在于：KVM 不会把 MMIO 地址映射成普通内存。

普通 RAM：

```text
GPA -> EPT/NPT -> HPA
```

MMIO 区域：

```text
GPA -> EPT/NPT 找不到普通 RAM 映射
    -> EPT violation / NPT fault
    -> VM-Exit
```

MMIO 捕获流程：

```text
Guest 写 MMIO 地址
        │
        ▼
CPU 进行 EPT/NPT 翻译
        │
        ▼
发现该 GPA 不是普通 RAM
        │
        ▼
EPT violation / NPT fault
        │
        ▼
VM-Exit 到 KVM
        │
        ▼
KVM 判断这是 MMIO
        │
        ▼
生成 KVM_EXIT_MMIO
        │
        ▼
QEMU 根据地址找到 MemoryRegion
        │
        ▼
调用设备 read/write callback
        │
        ▼
恢复 Guest
```

简化图：

```text
Guest
  store [MMIO addr]
    │
    ▼
EPT/NPT violation
    │
    ▼
KVM
  KVM_EXIT_MMIO
    │
    ▼
QEMU MemoryRegion
  e1000_mmio_write()
  virtio_pci_config_write()
  ahci_mmio_write()
    │
    ▼
resume Guest
```

---

## 四、 QEMU 如何知道哪个地址属于哪个设备

QEMU 创建虚拟机时，会构建一棵 Guest 物理地址空间：

```text
Guest physical address space
├── 0x00000000 - 0x7fffffff   RAM
├── 0xf0000000 - 0xf0000fff   virtio-net PCI BAR
├── 0xf0001000 - 0xf0001fff   e1000 MMIO BAR
├── 0xfee00000 - 0xfee00fff   local APIC
└── ...
```

RAM 区域通过 KVM API 注册成 memory slot：

```text
KVM_SET_USER_MEMORY_REGION
```

Guest 访问这些区域时，硬件可以直接走 EPT/NPT，不需要 VM-Exit。

设备 MMIO 区域则注册为 QEMU 的 `MemoryRegion`，不作为普通 RAM 映射给 KVM。
Guest 一访问这些地址，就会退出到 KVM/QEMU，QEMU 再按照地址派发到对应设备：

```text
0xf0001000 -> e1000
0xf0000000 -> virtio-net PCI config / notify
0xfee00000 -> local APIC
```

---

## 五、 传统设备模拟：以 e1000 发包为例

传统模拟设备会尽量表现得像真实硬件。例如 e1000 虚拟网卡：

```text
Guest e1000 driver
  -> 配置 TX descriptor ring
  -> 写 e1000 TX tail register
```

TX tail register 位于 e1000 PCI BAR，是 MMIO。

完整路径：

```text
Guest 写 TX tail MMIO
  -> EPT violation
  -> VM-Exit
  -> KVM_EXIT_MMIO
  -> QEMU e1000_mmio_write()
  -> QEMU 发现 TX tail 推进
  -> QEMU 从 Guest RAM 读取 TX descriptor
  -> QEMU 根据 descriptor 读取 packet buffer
  -> QEMU 把包发到 TAP / socket / backend
  -> QEMU 更新状态并注入中断
  -> resume Guest
```

这里 QEMU 模拟的是设备行为：

```text
寄存器变化
descriptor 消费
DMA 读写 Guest 内存
中断上报
```

这种方式兼容性好，但性能差。原因是：

```text
每次寄存器访问都可能 VM-Exit
设备模型复杂
QEMU 用户态参与频繁
数据路径可能有多次拷贝
```

---

## 六、 DMA 模拟：QEMU 如何读写 Guest 内存

真实设备 DMA 使用物理地址访问内存。

虚拟设备里，Guest descriptor 通常保存的是 GPA：

```text
descriptor.addr = Guest Physical Address
```

QEMU 要模拟 DMA，就需要把 GPA 转成自己能访问的 HVA：

```text
GPA -> HVA
```

因为 Guest RAM 本质上是 QEMU 进程 `mmap()` 出来的一段内存，QEMU 可以直接读写对应 HVA。

模拟 DMA 读：

```text
Guest descriptor 指向 packet buffer GPA
QEMU 将 GPA 转成 HVA
QEMU 从 HVA 读取 packet data
```

模拟 DMA 写：

```text
QEMU 收到网络包
QEMU 找到 Guest RX buffer GPA
QEMU 转成 HVA
QEMU 把 packet data 写入 HVA
```

这也是为什么内存虚拟化文章中的 HVA 很重要：

```text
硬件执行路径：GVA -> GPA -> HPA
QEMU 设备模拟路径：GPA -> HVA
```

---

## 七、 中断注入：Host 如何通知 Guest

设备完成工作后，需要通知 Guest。

传统模拟设备会通过虚拟中断通知 Guest：

```text
QEMU / KVM
  -> 注入虚拟 IRQ / MSI / MSI-X
  -> Guest 中断处理函数运行
  -> Guest driver 读取设备状态
```

路径：

```text
Host device model 完成 I/O
  -> KVM_SET_IRQ_LINE / irqfd
  -> KVM 注入虚拟中断
  -> Guest VM-entry
  -> Guest interrupt handler
```

高性能数据面通常会避免频繁中断。例如 DPDK PMD 更倾向于轮询：

```text
Guest DPDK virtio PMD
  -> 不等中断
  -> 主动轮询 used ring
```

---

## 八、 ioeventfd / irqfd：减少 QEMU 参与

传统路径里，Guest 每次写设备 doorbell 都可能退出到 QEMU。

`ioeventfd` 的作用是：当 Guest 写某个特定 PIO/MMIO 地址时，KVM 不必返回 QEMU，
而是直接 signal 一个 eventfd。

典型路径：

```text
Guest 写 virtio notify register
  -> VM-Exit 到 KVM
  -> KVM 匹配 ioeventfd
  -> signal eventfd
  -> vhost 后端被唤醒
  -> 不需要 QEMU 逐次处理这个写操作
```

`irqfd` 是反方向：

```text
Host 后端完成 I/O
  -> 写 eventfd
  -> KVM 注入虚拟中断给 Guest
```

这两个机制把"设备通知"从 QEMU 主循环里拆出去，是 virtio/vhost 加速的重要基础。

---

## 九、 virtio：用共享内存队列替代复杂设备模拟

virtio 的核心思想是：

```text
不要模拟复杂真实硬件；
Guest 和 Host 约定一种简单高效的虚拟设备协议。
```

virtio-net 不再要求 Host 模拟完整 e1000 寄存器和行为，而是使用 virtqueue：

```text
Descriptor Table
Available Ring
Used Ring
```

TX 方向：

```text
Guest virtio driver / DPDK virtio PMD
  -> 将 packet buffer descriptor 放进 available ring
  -> kick Host
  -> Host 处理 descriptor
  -> Host 更新 used ring
```

RX 方向：

```text
Guest 提前把空 RX buffer 放进 available ring
  -> Host 收到包
  -> Host 把 packet data 写入 Guest buffer
  -> Host 更新 used ring
  -> Guest 轮询或收到中断
```

virtio 仍然需要通知，但数据本身通过共享内存 ring 传递，避免了大量传统寄存器模拟。

---

## 十、 vhost / vhost-user：把 virtio 数据面从 QEMU 移出去

virtio 解决了设备模型复杂的问题，但如果所有 virtqueue 处理仍在 QEMU 主线程里，
性能仍然有限。

vhost 的目标是把 virtio 数据面移出去：

| 后端       | 数据面位置          | 典型场景                          |
| ---------- | ------------------- | --------------------------------- |
| vhost-net  | Host kernel         | Linux 内核加速 virtio-net         |
| vhost-user | Host 用户态进程     | OVS-DPDK、VPP、SPDK、DPDK backend |
| vDPA       | NIC / SmartNIC 硬件 | 硬件卸载 virtio 数据面            |

vhost-user 经典路径：

```text
Guest virtio PMD
  -> virtqueue in Guest memory
  -> QEMU 建立 vhost-user socket
  -> QEMU 将 Guest memory fd / vring 地址 / eventfd 传给后端
  -> OVS-DPDK / VPP / SPDK 直接处理 virtqueue
```

QEMU 仍然负责控制面：

```text
创建 VM
枚举 PCI 设备
协商 virtio feature
传递 vring 地址和 eventfd
```

但数据面可以由 vhost 后端处理：

```text
收发包
读写 virtqueue
搬运 packet data
更新 used ring
```

这就是 vhost-user 比纯 QEMU virtio 更快的原因。

### vhost 后端如何访问 Guest 内存

virtio/vhost 的共享内存不是额外发明的一块神秘内存，而是 **Guest RAM 本身**。

QEMU 启动 VM 时，会在 Host 上分配 Guest RAM：

```text
QEMU mmap() / memfd / hugetlbfs
  -> 得到 Host virtual address (HVA)
  -> 通过 KVM_SET_USER_MEMORY_REGION 注册给 KVM
  -> KVM 建立 GPA -> HPA 的 EPT/NPT 映射
```

因此有两条访问路径：

```text
Guest CPU 访问：
  GVA -> Guest page table -> GPA -> EPT/NPT -> HPA

Host/QEMU/vhost 访问：
  GPA -> memory region table -> HVA
```

virtqueue 的 descriptor、available ring、used ring，以及 RX/TX buffer 都在 Guest RAM 里。
Guest descriptor 里写的是 GPA：

```text
desc.addr = Guest Physical Address
```

Host vhost 后端处理时，会根据 QEMU 提供的 memory table 把 GPA 转成自己能访问的 HVA，
然后读写这块内存。

不同 vhost 后端的内存共享方式：

| 后端        | 如何访问 Guest memory                                                   |
| ----------- | ----------------------------------------------------------------------- |
| QEMU virtio | QEMU 本来就拥有 Guest RAM 的 HVA，直接访问                              |
| vhost-net   | QEMU 通过 ioctl 把 memory table 交给内核 vhost，内核侧访问 Guest memory |
| vhost-user  | QEMU 通过 Unix socket 把 memory fd、vring 地址、eventfd 传给用户态后端  |

所以问题可以拆开理解：

```text
KVM 支持：
  注册 Guest RAM、建立 GPA -> HPA 映射、处理 eventfd/irqfd、运行 vCPU。

QEMU 支持：
  分配 Guest RAM、维护 memory region、把 vhost 所需的内存和队列信息交给后端。

vhost-user 支持：
  外部用户态进程 mmap QEMU 传来的 memory fd，然后直接访问 Guest virtqueue。
```

因此，vhost-user 需要 Guest memory 对后端可映射。生产中常用 hugepage、memfd
或共享内存后端启动 VM，就是为了让 OVS-DPDK、VPP、SPDK 这类外部进程能映射
Guest RAM。

### GPA 到 HVA 的转换与页替换问题

vhost-user 后端处理 descriptor 时，看到的是 Guest 写入的地址：

```text
desc.addr = GPA
```

后端不能直接解引用 GPA，因为 GPA 只是 Guest 视角的物理地址。它需要根据 QEMU
传来的 memory regions 做一次转换：

```text
GPA
  -> 找到包含该 GPA 的 memory region
  -> HVA = region.userspace_addr + (GPA - region.guest_phys_addr)
  -> 后端用 HVA 读写 Guest buffer
```

DPDK vhost-user 后端内部就维护了这样的 memory table，并在访问 virtqueue buffer
时完成 GPA/IOVA 到 host virtual address 的转换。

页替换要分场景看：

```text
软件 vhost-user 后端：
  后端通过 mmap 得到 HVA，用 CPU load/store 访问。
  如果底层页被换出，会触发 page fault，功能上仍可恢复，但性能会严重抖动。

硬件 DMA / vDPA / VFIO：
  设备直接 DMA，必须依赖 IOMMU 映射和页固定，不能让 DMA 目标页随意被换出。
```

高性能虚拟化通常避免普通匿名内存被换出：

```bash
# 常见 QEMU 思路，示意
-object memory-backend-file,id=mem0,size=4G,\
  mem-path=/dev/hugepages,share=on,prealloc=on \
-numa node,memdev=mem0
```

原因：

| 手段        | 作用                                              |
| ----------- | ------------------------------------------------- |
| hugepage    | hugetlb 页不可 swap，TLB 压力更小                 |
| share=on    | 允许 vhost-user 后端 mmap 同一块 Guest memory     |
| prealloc=on | 启动时提前分配并 fault-in，避免运行时首次缺页抖动 |
| mlock       | 对普通内存可防止被 swap，但需要权限和内存限制配置 |

所以结论是：

```text
vhost-user 后端确实要做 GPA -> HVA 转换；
生产环境通常用 hugepage/prealloc/mlock 避免页替换和运行时 page fault。
```

---

## 十一、 VFIO / SR-IOV：绕过设备模拟

如果追求接近裸机性能，可以不让 QEMU 模拟设备，而是把真实设备或 VF 交给 Guest。

典型方案：

```text
PCI passthrough:
  整个 PCI 设备直通给 VM

SR-IOV:
  物理网卡创建多个 VF
  每个 VF 可以分配给不同 VM
```

这时路径变成：

```text
Guest driver
  -> 真实 VF/PCI 设备
  -> IOMMU 限制 DMA 范围
  -> 物理硬件
```

VFIO 的关键职责：

```text
安全暴露 PCI BAR 给 Guest
配置 IOMMU DMA 隔离
处理中断重映射
防止设备 DMA 访问其他 VM 或 Host 内存
```

对 DPDK 来说：

```text
virtio PMD:
  驱动 Guest virtio-net 虚拟设备

mlx5 / i40e / ixgbe PMD:
  驱动直通进 Guest 的 VF 或真实 NIC
```

---

## 十二、 三种 I/O 虚拟化路径对比

| 路径           | Guest 看到的设备 | Host 数据面       | 性能 | 灵活性 | 典型用途                  |
| -------------- | ---------------- | ----------------- | ---- | ------ | ------------------------- |
| 传统设备模拟   | e1000 / AHCI 等  | QEMU 设备模型     | 低   | 高     | 兼容老系统                |
| virtio + vhost | virtio-net/blk   | kernel/user vhost | 高   | 高     | 云主机、NFV、DPDK/vSwitch |
| VFIO / SR-IOV  | 真实 PCI/VF      | 硬件直通          | 最高 | 低     | 高性能网络、低延迟业务    |

选择逻辑：

```text
要兼容性：传统模拟
要性能与灵活性平衡：virtio + vhost
要极限性能：VFIO / SR-IOV
```

---

## 十三、 与前后章节的关系

这篇文章处在虚拟化机制链路的 I/O 层：

```text
CPU 虚拟化：
  vCPU 线程、VMCS/VMCB、VM-Entry/VM-Exit
  -> [[2026-03-31-kvm-cpu-virtualization-mechanisms|KVM CPU 虚拟化核心机制]]

内存虚拟化：
  GVA/GPA/HVA/HPA、EPT/NPT
  -> [[2026-03-31-kvm-memory-virtualization-deep-dive|KVM 内存虚拟化深度解析]]

I/O 虚拟化：
  PIO/MMIO trap、QEMU 设备模拟、virtio/vhost、VFIO
  -> 本文

DPDK virtio:
  Guest virtio PMD 如何读写 virtqueue
  -> [[2026-04-09-dpdk-deep-dive-ch25-virtio-driver|DPDK Virtio 驱动]]
```

---

## 十四、 小结

1. **PIO 捕获**：x86 `in/out` 通过 I/O bitmap 控制，命中拦截后触发 VM-Exit，KVM 返回 `KVM_EXIT_IO` 给 QEMU。
2. **MMIO 捕获**：设备 GPA 不映射为普通 RAM，Guest load/store 触发 EPT/NPT violation，KVM 返回 `KVM_EXIT_MMIO`。
3. **QEMU 设备模型**：QEMU 维护 Guest 物理地址空间和设备 `MemoryRegion`，通过回调模拟寄存器、DMA、中断。
4. **模拟 DMA**：Guest descriptor 通常保存 GPA，QEMU 将 GPA 转成 HVA 后读写 Guest memory。
5. **中断注入**：Host 通过 KVM 注入虚拟 IRQ/MSI/MSI-X；高性能路径常用轮询减少中断。
6. **ioeventfd/irqfd**：把通知路径从 QEMU 主循环中拆出来，降低 virtio doorbell 和 interrupt 的用户态开销。
7. **virtio**：用共享内存 virtqueue 替代复杂真实设备模拟，减少寄存器 trap。
8. **vhost/vhost-user**：把 virtio 数据面从 QEMU 移到 kernel、用户态 backend 或硬件。
9. **VFIO/SR-IOV**：通过 IOMMU 和中断重映射安全直通设备，性能最高但灵活性较低。
