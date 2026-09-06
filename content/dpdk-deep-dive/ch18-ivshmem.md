---
title: "DPDK 深度探索 (十八)：IVSHMEM VM 间共享内存"
date: 2026-04-09
tags: [dpdk, series, ivshmem, VM, shared-memory, doorbell, PCIe, zero-copy]
description: "深入理解 IVSHMEM 机制——无 hypervisor 参与的 VM 间高速共享内存、doorbell 通知、PCIe BAR 映射、DPDK IVSHMEM 库"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-17. 前十七章已完成 18. **第十八章：IVSHMEM VM 间共享内存**

---

## 1. 概述：什么是 IVSHMEM？

> [!tip] 一句话理解 IVSHMEM
> **IVSHMEM = 让同一台物理机上的多个 VM 共享同一块内存。**
>
> 你可以把它理解为"VM 之间的共享白板"——VM1 往白板上写数据，VM2 可以直接看到并读取，中间不经过任何拷贝。
>
> 这和 RDMA 的区别在于：
>
> - **RDMA**：跨机器，网卡直接写到**另一台机器**的内存（需要 RDMA 网卡 + 专用网络）
> - **IVSHMEM**：同一台机器内的 VM 之间，直接访问**同一块物理内存**（不需要特殊硬件，QEMU 提供 PCIe 设备即可）
>
> IVSHMEM 的典型场景不是"把网络流量直接写到 VM 内存"（那是 SR-IOV/vhost-user 的事），而是**同主机多个 VM 之间需要共享数据**——比如 NFV 场景中，防火墙 VM 和负载均衡 VM 需要快速交换连接表信息。

> [!caution] 现实情况：了解即可，生产慎用
> IVSHMEM 是 QEMU 提供的一个虚拟设备特性，QEMU 本身没有废弃它，但**主流云平台和 VNF 产品基本没有采用**：
>
> - OpenStack / KubeVirt 不支持 IVSHMEM 设备分配
> - DPDK 的 IVSHMEM 库已在 20.05 移除
> - SPDK 从未支持过 IVSHMEM
> - 学术论文里常见，工业界几乎没有落地案例
>
> 原因很简单：**能用一个 VM 解决的，没人拆成多个 VM 再用 IVSHMEM 拼。** 真正需要 VM 间高性能通信的场景，现在更倾向于 SR-IOV 直通、eBPF/XDP 卸载、P4 可编程网卡、智能网卡（DPU）等方案。
>
> **本章定位**：作为虚拟化原理的学习材料，理解 PCIe BAR 映射、VM 间共享内存、doorbell 通知机制。这些知识对理解后续的 VDPA、SR-IOV 等技术也有帮助。

### 1.1 IVSHMEM 背景

传统的 VM 间通信需要经过 hypervisor 或物理网络，而 IVSHMEM (Inter-VM Shared Memory) 提供了**直接共享内存**的机制：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    VM 间通信方式对比                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  方式 1: 传统网络 (virtio-net / vhost-user)                                │
│  ────────────────────────────────────────                                  │
│  VM1 ──► hypervisor ──► VM2                                               │
│              │                                                             │
│              ▼                                                             │
│         虚拟网络栈                                                          │
│         延迟高 (~10-100μs)                                                 │
│                                                                             │
│  方式 2: IVSHMEM (共享内存)                                                │
│  ─────────────────────────────                                             │
│                                                                             │
│  ┌──────────────────────────────────────────────────────────────────────┐ │
│  │                       Host Physical Memory                           │ │
│  │   ┌─────────────────────────────────────────────────────────────┐   │ │
│  │   │                    Shared Memory Region                      │   │ │
│  │   │                     (IVSHMEM Bar)                            │   │ │
│  │   │                                                              │   │
│  │   │   VM1 ──────────────► │ ◄────────────── VM2                  │   │ │
│  │   │   (直接读写)           │    (直接读写)                         │   │ │
│  │   └─────────────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  优势：                                                                    │
│  - 无 hypervisor 介入                                                      │
│  - 零拷贝数据路径                                                          │
│  - 超低延迟 (~1μs 以内)                                                    │
│  - 高吞吐量 (PCIe 带宽)                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 IVSHMEM vs 其他 VM 通信方式

| 特性           | IVSHMEM                   | vhost-user | KNI      | 物理网络   |
| -------------- | ------------------------- | ---------- | -------- | ---------- |
| **延迟**       | ~5-15μs                   | ~5-10μs    | ~50μs    | ~100μs+    |
| **吞吐量**     | PCIe 带宽                 | PCIe 带宽  | 受限     | 受网络限制 |
| **Hypervisor** | 数据路径无，通知走 VMEXIT | 极少       | 每次操作 | 完整协议栈 |
| **复杂度**     | 中等                      | 高         | 低       | 高         |
| **可靠性**     | VM 故障可能丢数据         | 高         | 高       | 高         |
| **使用场景**   | VM 间高速数据交换         | VM-宿主机  | 控制平面 | 跨主机     |

### 1.3 IVSHMEM 应用场景

| 场景              | 说明                                                  |
| ----------------- | ----------------------------------------------------- |
| **NFV**           | VNF 组件间高速数据交换（最典型）                      |
| **实时消息**      | 同主机低延迟消息队列                                  |
| **AI 推理**       | 多个 VM 协同推理，共享模型权重（只读场景）            |
| **DPDK 共享**     | 多 VM 共享 rte_ring / mbuf 池（已移除，见 Section 5） |
| **DPDK 白盒测试** | 同主机多进程模拟多 VM 通信                            |

### 1.4 经典场景完整流程：NFV 防火墙 + NAT 联动

假设一台物理机上跑了两个 VM：**防火墙 VM** 和 **NAT VM**。包从物理网卡进来 → 防火墙 VM 检查 → 合法包交给 NAT VM 做地址转换 → 发回去。

问题是：防火墙 VM 已经建立的连接状态（五元组 → 合法标记），NAT VM 需要知道，否则 NAT 要重新查一遍规则，浪费 CPU。

IVSHMEM 就用来**共享连接状态表**，两个 VM 读写同一块内存，零拷贝：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        NFV 防火墙 + NAT 联动                                 │
│                        (IVSHMEM 经典场景)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  物理网卡 ──► vhost-user ──► ┌──────────────┐                               │
│  (DPDK PMD)                 │  防火墙 VM    │                               │
│                              │  (FW)        │                               │
│                              └──────┬───────┘                               │
│                                     │                                      │
│                                     │ ① 查连接表: 新连接?                    │
│                                     │    └─ 是 → 匹配规则 → 合法?           │
│                                     │         └─ 是 → 写入连接表到 IVSHMEM  │
│                                     │                                   │
│                                     ▼                                   │
│  ┌──────────────────────────────────────────────────────────────┐         │
│  │              IVSHMEM 共享内存 (256MB)                          │         │
│  │                                                              │         │
│  │  ┌────────────────────────────────────────────────────┐     │         │
│  │  │  Connection Table (连接状态表)                       │     │         │
│  │  │                                                    │     │         │
│  │  │  五元组 (src_ip, dst_ip, src_port, dst_port, proto) │     │         │
│  │  │  → state (NEW / ESTABLISHED / FIN)                  │     │         │
│  │  │  → fw_verdict (ALLOW / DENY)                         │     │         │
│  │  │  → nat_action (SNAT / DNAT / NONE)                  │     │         │
│  │  │  → timestamp                                         │     │         │
│  │  │                                                    │     │         │
│  │  └────────────────────────────────────────────────────┘     │         │
│  │                                                              │         │
│  └──────────────────────────────────────────────────────────────┘         │
│                                     ▲                                   │
│                                     │ ② 读连接表: 已有? → 直接 NAT        │
│                                     │    └─ 没有 → 回查规则                 │
│                              ┌──────┴───────┐                               │
│                              │  NAT VM      │                               │
│                              │  (地址转换)    │                               │
│                              └──────┬───────┘                               │
│                                     │                                      │
│                                     │ ③ 做地址转换                         │
│                                     │    SNAT: 10.0.0.x → 203.0.113.x    │
│                                     ▼                                      │
│                              vhost-user ──► 物理网卡 ──► 发送到外部         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

**时序图（单包处理全流程）：**

```
  外部包到达        防火墙 VM                    IVSHMEM                 NAT VM
  ──────────        ─────────                    ───────                 ──────
      │                  │                          │                      │
      │  ① vhost-user    │                          │                      │
      │  递包到 FW VM    │                          │                      │
      │─────────────────►│                          │                      │
      │                  │                          │                      │
      │                  │ ② 查连接表 (hash lookup)  │                      │
      │                  │─────────────────────────►│                      │
      │                  │                          │                      │
      │                  │  ③ 新连接, 未命中         │                      │
      │                  │◄─────────────────────────│                      │
      │                  │                          │                      │
      │                  │ ④ 匹配 ACL 规则: ALLOW   │                      │
      │                  │                          │                      │
      │                  │ ⑤ 写入新连接条目          │                      │
      │                  │─────────────────────────►│                      │
      │                  │   (五元组 + ALLOW)        │                      │
      │                  │                          │                      │
      │                  │ ⑥ doorbell 通知 NAT VM   │                      │
      │                  │──MMIO──► QEMU ──中断────►│                      │
      │                  │                          │                      │
      │                  │                          │  ⑦ 收到 doorbell      │
      │                  │                          │                      │
      │                  │                          │  ⑧ 读连接表           │
      │                  │                          │─────────────────────►│
      │                  │                          │  命中! state=ALLOW     │
      │                  │                          │◄─────────────────────│
      │                  │                          │                      │
      │                  │                          │  ⑨ 做 SNAT 转换      │
      │                  │                          │  10.0.0.5→203.0.113.1│
      │                  │                          │                      │
      │                  │                          │  ⑩ 更新连接表         │
      │                  │                          │  state=ESTABLISHED    │
      │                  │                          │                      │
      │                  │                          │  ⑪ vhost-user 发包   │
      │                  │                          │──────────────────────│──►
      │  ⑫ 包从物理网卡发出                                                      │
      │                  │                          │                      │
      ▼                  ▼                          ▼                      ▼
```

**对比没有 IVSHMEM 的方案：**

```
  没有 IVSHMEM 时，FW → NAT 需要走虚拟网络：

  防火墙 VM ──► virtio-net ──► QEMU 虚拟交换机 ──► virtio-net ──► NAT VM
                  拷贝一次              VMEXIT           拷贝一次

  延迟: ~20-50μs（两次数据拷贝 + 两次 VMEXIT）

  有 IVSHMEM 时：

  防火墙 VM ──► 写共享内存 ──► doorbell ──► NAT VM 读共享内存

  延迟: ~5-15μs（零拷贝，只有 doorbell 一次 VMEXIT）
```

> [!note] 和 RDMA 的本质区别
> 上面的场景中，防火墙 VM 和 NAT VM 在**同一台物理机**上，所以用 IVSHMEM（共享内存）就够了。如果它们在**不同物理机**上，就需要 RDMA 或传统网络。IVSHMEM 不跨机器，不需要 RDMA 网卡。

> [!warning] 为什么不把防火墙和 NAT 放同一个 VM？
> 这是最自然的疑问。自己写代码的话，一个进程搞定防火墙 + NAT，根本不需要 IVSHMEM，性能还更好。
>
> IVSHMEM 存在的真实原因是**商业生态约束**，不是技术最优解：
>
> | 约束             | 说明                                                                                    |
> | ---------------- | --------------------------------------------------------------------------------------- |
> | **不同厂商**     | 防火墙 VM 是 A 公司产品，NAT VM 是 B 公司产品，买来部署在同一台物理机上，改不了对方代码 |
> | **安全域隔离**   | 合规要求防火墙和 NAT 跑在独立 VM 中，故障不互相影响                                     |
> | **云平台灵活性** | 运营商想自由组合 VNF（今天加 DPI，明天换 LB），不想每次重新编译                         |
>
> **结论**：如果你能控制所有代码，把功能合并到一个 VM/进程里，别用 IVSHMEM。IVSHMEM 是"不得不拆成多个 VM"时的补救方案。

---

## 2. IVSHMEM 架构

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          IVSHMEM 架构                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                         QEMU                                         │  │
│  │                                                                     │  │
│  │  ┌─────────────┐          ┌─────────────┐          ┌─────────────┐  │  │
│  │  │   VM1       │          │   VM2       │          │   VM3       │  │  │
│  │  │  IVSHMEM   │          │  IVSHMEM   │          │  IVSHMEM   │  │  │
│  │  │  Driver    │          │  Driver    │          │  Driver    │  │  │
│  │  └──────┬──────┘          └──────┬──────┘          └──────┬──────┘  │  │
│  │         │                        │                        │         │  │
│  │         │ PCIe BAR               │ PCIe BAR               │ PCIe BAR│  │
│  │         └────────────┬───────────┴───────────┬────────────┘         │  │
│  │                        │                       │                     │  │
│  └────────────────────────┼───────────────────────┼─────────────────────┘  │
│                           │                       │                        │
│  ┌────────────────────────┼───────────────────────┼─────────────────────┐  │
│  │                        ▼                       ▼                     │  │
│  │  ┌─────────────────────────────────────────────────────────────┐     │  │
│  │  │              IVSHMEM Device (PCIe)                         │     │  │
│  │  │                                                             │     │  │
│  │  │  ┌───────────────┐  ┌───────────────┐  ┌───────────────┐    │     │  │
│  │  │  │  Doorbell    │  │   Memory     │  │  Configuration│    │     │  │
│  │  │  │  Registers   │  │   BAR        │  │  Registers   │    │     │  │
│  │  │  │  (0x00-0xFF) │  │  (映射共享内存)│  │  (0x100+)    │    │     │  │
│  │  │  └───────────────┘  └───────────────┘  └───────────────┘    │     │  │
│  │  │                                                             │     │  │
│  │  └─────────────────────────────────────────────────────────────┘     │  │
│  │                                                                    │  │
│  │                        QEMU (Hypervisor)                          │  │
│  └────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 IVSHMEM PCIe 设备

IVSHMEM 以标准 PCIe 设备呈现给 VM，但不同变体的 BAR 布局差异很大：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    三种 IVSHMEM 变体的 BAR 布局                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. ivshmem (legacy)                                                        │
│  ───────────────────                                                        │
│  BAR0: MSI-X Table / Capability                                           │
│  BAR1: Shared Memory (直接映射)                                             │
│  BAR2: Doorbell (写入触发中断)                                              │
│                                                                             │
│  2. ivshmem-plain                                                            │
│  ─────────────────                                                          │
│  BAR0: Shared Memory (直接映射)                                             │
│  BAR1: 无                                                                   │
│  BAR2: 无                                                                   │
│  → 最简单，没有 doorbell，没有中断通知能力                                    │
│                                                                             │
│  3. ivshmem-doorbell (推荐)                                                  │
│  ───────────────────────────                                                │
│  BAR0: IVPosition — 只读，返回本 VM 的 ID                                   │
│  BAR1: Doorbell   — 写入，通知目标 VM                                       │
│  BAR2: Shared Memory — 共享内存区域                                         │
│                                                                             │
│  → 有 doorbell 中断，支持多 VM 间通知                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

> [!warning] BAR 布局陷阱
> 三种变体的 BAR 含义完全不同！legacy 的 BAR1 是共享内存，doorbell 的 BAR1 是 doorbell 寄存器。混用配置会导致错误映射，是新手最容易踩的坑。

ivshmem-doorbell 变体的寄存器非常简单——**只有两个 4 字节寄存器**：

```c
// BAR0: IVPosition (read-only)
// 读取返回本 VM 在共享内存中的 ID (0-based)
// 用途: 让 VM 知道"我是谁"
volatile uint32_t iv_position;

// BAR1: Doorbell (write-only)
// 写入格式: (target_vm_id << 16) | vector
// QEMU 收到此写入后，向 target_vm_id 发送 MSI-X 中断
// 用途: "告诉目标 VM 有新数据"
//
// 示例:
//   *(volatile uint32_t *)bar1 = (2 << 16) | 0;  // 通知 VM2, vector 0
//   *(volatile uint32_t *)bar1 = (1 << 16) | 3;  // 通知 VM1, vector 3
volatile uint32_t doorbell;

// BAR2: Shared Memory
// 直接映射到 Host 物理内存，所有 VM 看到同一块地址空间
// 大小由 QEMU 启动参数决定
void *shared_memory;
```

### 2.3 Doorbell 机制

> [!important] Doorbell ≠ 零开销通知
> 共享内存的**读写**确实不经过 hypervisor（零拷贝），但 doorbell **通知**是 MMIO 写入，会触发 VMEXIT，由 QEMU 处理后再注入中断到目标 VM。整个通知路径延迟约 5-10μs。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    Doorbell 通知完整路径                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  VM1                              QEMU/Hypervisor              VM2          │
│  ────                             ───────────────              ────          │
│                                                                             │
│  1. 写数据到共享内存 ──────────────────────────────────────────────►        │
│     (零拷贝，无 VMEXIT)                                                     │
│                                                                             │
│  2. 写 BAR1 doorbell         ──► VMEXIT                                    │
│     = (vm2_id << 16) | vec          │                                     │
│                                       │ 3. QEMU 解析 doorbell              │
│                                       │    提取 target_vm_id 和 vector     │
│                                       │                                    │
│                                       └──► 4. 注入 MSI-X 中断到 VM2 ──►   │
│                                                                             │
│  5. VM2 中断处理函数被调用                                                  │
│     从共享内存读取 VM1 写入的数据                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

```c
// --- VM 侧: 发送通知 ---

// BAR1 doorbell 寄存器地址 (由 mmap PCI BAR 获得)
static volatile uint32_t *g_doorbell;

// 通知目标 VM
void ivshmem_notify(uint16_t target_vm_id, uint32_t vector)
{
    // 写入 doorbell: 高 16 位 = 目标 VM ID, 低 16 位 = 中断向量
    // 这个写操作触发 VMEXIT → QEMU 转发 → 目标 VM 收到中断
    *g_doorbell = ((uint32_t)target_vm_id << 16) | (vector & 0xFFFF);
}

// --- VM 侧: 接收通知 (内核驱动中断处理) ---

static irqreturn_t
ivshmem_interrupt(int irq, void *dev_id)
{
    struct ivshmem_device *dev = dev_id;

    // 中断处理: 从共享内存中读取数据
    // 具体处理逻辑取决于应用层协议 (ring, queue 等)
    wake_up_interruptible(&dev->waitq);

    return IRQ_HANDLED;
}
```

---

## 3. QEMU IVSHMEM 配置

### 3.1 QEMU 命令行配置

**方式一：ivshmem-plain（最简单，无 doorbell）**

```bash
# 先创建共享内存文件
mkdir -p /dev/shm
truncate -s 256M /dev/shm/ivshmem0
chmod 666 /dev/shm/ivshmem0

# VM1
qemu-system-x86_64 \
    -m 2G \
    -object memory-backend-file,id=shmem0,size=256M,share=on,mem-path=/dev/shm/ivshmem0 \
    -device ivshmem-plain,memdev=shmem0 \
    ...

# VM2（同一台 Host，共享同一个文件）
qemu-system-x86_64 \
    -m 2G \
    -object memory-backend-file,id=shmem0,size=256M,share=on,mem-path=/dev/shm/ivshmem0 \
    -device ivshmem-plain,memdev=shmem0 \
    ...
```

> [!note] ivshmem-plain 的 VM 数量没有限制
> 任意多个 VM 都可以使用同一个共享内存文件。限制是**没有 doorbell 通知**，需要另想办法（轮询、eventfd、或自建通知机制）。

**方式二：ivshmem-doorbell（推荐，支持中断通知）**

```bash
# 创建共享内存文件
truncate -s 256M /dev/shm/ivshmem0

# VM1（每个 VM 的 vectors = 它能接收的中断向量数，>= 其他 VM 的数量）
qemu-system-x86_64 \
    -m 2G \
    -object memory-backend-file,id=shmem0,size=256M,share=on,mem-path=/dev/shm/ivshmem0 \
    -device ivshmem-doorbell,memdev=shmem0,vectors=4 \
    ...

# VM2
qemu-system-x86_64 \
    -m 2G \
    -object memory-backend-file,id=shmem0,size=256M,share=on,mem-path=/dev/shm/ivshmem0 \
    -device ivshmem-doorbell,memdev=shmem0,vectors=4 \
    ...

# VM3
qemu-system-x86_64 \
    -m 2G \
    -object memory-backend-file,id=shmem0,size=256M,share=on,mem-path=/dev/shm/ivshmem0 \
    -device ivshmem-doorbell,memdev=shmem0,vectors=4 \
    ...
```

> [!warning] vectors 参数的含义
> `vectors` 是本 VM 能接收的 MSI-X 中断向量数，**不是 VM 总数**。如果 VM1 要能收到 VM2 和 VM3 的 doorbell 通知，VM1 的 vectors 至少要 2。每个 VM 之间互相通知需要 vectors >= (VM 总数 - 1)。

### 3.2 IVSHMEM 设备类型

| 设备类型           | BAR 布局                                 | Doorbell    | 适用场景               |
| ------------------ | ---------------------------------------- | ----------- | ---------------------- |
| `ivshmem-plain`    | BAR0=共享内存                            | 无          | 最简单，轮询或自建通知 |
| `ivshmem-doorbell` | BAR0=IVPos, BAR1=Doorbell, BAR2=共享内存 | 有（MSI-X） | 推荐，支持中断通知     |
| `ivshmem` (legacy) | BAR0=MSI-X, BAR1=共享内存, BAR2=Doorbell | 有          | 旧版 QEMU 兼容         |

### 3.3 共享内存文件

```bash
# 创建共享内存文件 (推荐 truncate)
truncate -s 256M /dev/shm/ivshmem0

# 设置权限 (所有 VM 需要读写)
chmod 666 /dev/shm/ivshmem0

# 查看
ls -lh /dev/shm/ivshmem0
```

---

## 4. Linux IVSHMEM 驱动

> [!warning] 内核主线没有 IVSHMEM 驱动
> Linux 主线内核**从未合入** IVSHMEM 字符设备驱动。`/dev/ivshmem0` 需要自行编译 out-of-tree 模块（如 [ngrechanov/ivshmem-guest](https://github.com/ngrechanov/ivshmem-guest) 或 Red Hat 的 [ivshmem-guest](https://github.com/vivier/ivshmem-guest)）。
>
> 另一种方式是直接在用户态 mmap `/sys/bus/pci/devices/.../resource2` 访问 BAR2 共享内存，无需驱动。下面的代码展示了这种直接访问方式。

### 4.1 驱动初始化 (out-of-tree, 概念性)

```c
// kernel/drivers/misc/ivshmem.c

static int
ivshmem_probe(struct pci_dev *pdev, const struct pci_device_id *ent)
{
    struct ivshmem_device *ivdev;
    resource_size_t bar0_addr, bar2_addr;
    resource_size_t bar0_size, bar2_size;

    // 分配设备结构
    ivdev = devm_kzalloc(&pdev->dev, sizeof(*ivdev), GFP_KERNEL);

    // 使能 PCI device
    if (pci_enable_device(pdev))
        return -EIO;

    // 获取 BAR0 (配置寄存器)
    bar0_addr = pci_resource_start(pdev, 0);
    bar0_size = pci_resource_len(pdev, 0);
    ivdev->bar0 = devm_ioremap(&pdev->dev, bar0_addr, bar0_size);

    // 获取 BAR2 (共享内存)
    bar2_addr = pci_resource_start(pdev, 2);
    bar2_size = pci_resource_len(pdev, 2);
    ivdev->shmem = devm_ioremap(&pdev->dev, bar2_addr, bar2_size);
    ivdev->shmem_size = bar2_size;

    // 读取 VM ID
    ivdev->vm_id = readl(ivdev->bar0 + IVSHMEM_VM_ID);

    // 获取共享内存物理地址
    ivdev->shmem_phys = readq(ivdev->bar0 + IVSHMEM_SHMEM_PHYS);

    // 注册中断处理
    if (pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSIX) > 0) {
        ivdev->vectors = pci_irq_vectors(pdev);
        request_irq(ivdev->vectors[0], ivshmem_interrupt,
                    IRQF_SHARED, "ivshmem", ivdev);
    }

    // 注册字符设备
    ivdev->cdev = cdev_alloc();
    ivdev->cdev->ops = &ivshmem_fops;
    cdev_add(&ivdev->cdev, MKDEV(IVSHMEM_MAJOR, ivdev->vm_id), 1);

    return 0;
}

// 字符设备操作
static const struct file_operations ivshmem_fops = {
    .owner = THIS_MODULE,
    .mmap = ivshmem_mmap,        // 映射共享内存到用户态
    .read = ivshmem_read,        // 读取共享内存
    .write = ivshmem_write,      // 写入共享内存
    .poll = ivshmem_poll,        // 轮询 (用于 eventfd)
    .unlocked_ioctl = ivshmem_ioctl,  // IO 控制
};
```

### 4.2 mmap 共享内存

```c
// 将共享内存映射到用户态进程
static int
ivshmem_mmap(struct file *filp, struct vm_area_struct *vma)
{
    struct ivshmem_device *dev = filp->private_data;
    unsigned long pfn;

    // 共享内存直接映射 (不需要拷贝)
    pfn = dev->shmem_phys >> PAGE_SHIFT;

    // 使用 remap_pfn_range 进行零拷贝映射
    if (remap_pfn_range(vma, vma->vm_start, pfn,
                        vma->vm_end - vma->vm_start,
                        vma->vm_page_prot)) {
        return -EAGAIN;
    }

    vma->vm_flags |= VM_DONTEXPAND | VM_DONTCOPY;

    return 0;
}

// 用户态代码
int
main(void)
{
    // 打开 IVSHMEM 设备
    int fd = open("/dev/ivshmem0", O_RDWR);

    // 获取共享内存大小
    struct ivshmem_info info;
    ioctl(fd, IVSHMEM_GET_INFO, &info);

    // mmap 共享内存
    void *shmem = mmap(NULL, info.shmem_size, PROT_READ | PROT_WRITE,
                       MAP_SHARED, fd, 0);

    // 直接使用共享内存
    struct shared_header *header = shmem;
    void *data = shmem + header->data_offset;

    // ...
}
```

---

## 5. 实战：不依赖 DPDK 库的 IVSHMEM 使用

> [!warning] DPDK IVSHMEM 库已移除
> DPDK 的 `rte_ivshmem` 库在 **DPDK 19.11 标记废弃，20.05 正式移除**。当前 DPDK 不再提供 IVSHMEM 相关 API。下面的实战方案使用标准 Linux 接口（PCI sysfs + mmap）直接访问 IVSHMEM，不依赖任何特殊库。

### 5.1 直接访问 IVSHMEM（无驱动方案）

不需要编译内核驱动，直接通过 `/sys/bus/pci/` 映射 PCI BAR：

```c
// ivshmem_direct.c — access IVSHMEM without any special driver

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>

struct ivshmem_ctx {
    int      vm_id;
    void    *bar0;       // IVPosition (ivshmem-doorbell)
    void    *bar1;       // Doorbell (ivshmem-doorbell)
    void    *bar2;       // Shared Memory
    size_t   bar2_size;
};

// find IVSHMEM PCI device BDF (e.g. 0000:00:05.0)
static int
find_ivshmem_device(char *bdf, size_t bdf_len)
{
    FILE *f = popen("lspci -D | grep 'Red Hat, Inc. Device 1110'", "r");
    if (!f) return -1;

    char line[256];
    if (fgets(line, sizeof(line), f)) {
        // line: "0000:00:05.0 Red Hat, Inc.: Device 1110 ..."
        strncpy(bdf, line, bdf_len - 1);
        bdf[strcspn(bdf, " \t")] = '\0';
        pclose(f);
        return 0;
    }
    pclose(f);
    return -1;
}

// map a PCI BAR region via sysfs
static void *
map_pci_bar(const char *bdf, int bar_num, size_t *size_out)
{
    char path[256];
    snprintf(path, sizeof(path),
             "/sys/bus/pci/devices/%s/resource%d", bdf, bar_num);

    // read BAR size
    char size_path[256];
    snprintf(size_path, sizeof(size_path),
             "/sys/bus/pci/devices/%s/resource%d_len", bdf, bar_num);
    FILE *f = fopen(size_path, "r");
    if (!f) return NULL;
    size_t size;
    fscanf(f, "%zu", &size);
    fclose(f);

    int fd = open(path, O_RDWR | O_SYNC);
    if (fd < 0) return NULL;

    void *addr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);

    if (addr == MAP_FAILED) return NULL;
    if (size_out) *size_out = size;
    return addr;
}

// initialize IVSHMEM context
static int
ivshmem_init(struct ivshmem_ctx *ctx)
{
    char bdf[64];
    if (find_ivshmem_device(bdf, sizeof(bdf)) < 0) {
        fprintf(stderr, "IVSHMEM PCI device not found\n");
        return -1;
    }
    printf("Found IVSHMEM device: %s\n", bdf);

    // map BARs (ivshmem-doorbell variant)
    ctx->bar0 = map_pci_bar(bdf, 0, NULL);       // IVPosition
    ctx->bar1 = map_pci_bar(bdf, 1, NULL);       // Doorbell
    ctx->bar2 = map_pci_bar(bdf, 2, &ctx->bar2_size);  // Shared Memory

    if (!ctx->bar0 || !ctx->bar1 || !ctx->bar2) {
        fprintf(stderr, "Failed to map PCI BARs\n");
        return -1;
    }

    // read VM ID from BAR0 (IVPosition register)
    ctx->vm_id = *(volatile uint32_t *)ctx->bar0;
    printf("VM ID: %d, Shared memory: %zu MB\n",
           ctx->vm_id, ctx->bar2_size / (1024 * 1024));

    return 0;
}

// notify target VM via doorbell
static inline void
ivshmem_notify(struct ivshmem_ctx *ctx, uint16_t target_vm_id)
{
    *(volatile uint32_t *)ctx->bar1 =
        ((uint32_t)target_vm_id << 16) | 0;  // vector 0
}
```

### 5.2 共享内存上的无锁 Ring

在 IVSHMEM 上构建通信协议，最简单的方式是在共享内存中放一个 SPSC ring：

```c
// SPSC ring for IVSHMEM (single producer, single consumer)
// placed in shared memory, accessed by two VMs

#define RING_SIZE 1024  // must be power of 2

struct ivshmem_ring {
    uint32_t head __attribute__((aligned(64)));   // consumer index
    uint32_t tail __attribute__((aligned(64)));   // producer index
    uint32_t mask;  // RING_SIZE - 1
    // data follows: ring->data[0..RING_SIZE-1]
    uint8_t data[];
} __attribute__((packed));

static inline struct ivshmem_ring *
ivshmem_ring_init(void *addr)
{
    struct ivshmem_ring *r = (struct ivshmem_ring *)addr;
    r->head = 0;
    r->tail = 0;
    r->mask = RING_SIZE - 1;
    return r;
}

// enqueue (producer — one VM)
static inline int
ivshmem_ring_enqueue(struct ivshmem_ring *r, const void *data, uint32_t len)
{
    uint32_t tail = r->tail;
    uint32_t next = (tail + 1) & r->mask;
    if (next == r->head) return -ENOBUFS;  // full

    memcpy(&r->data[tail * len], data, len);
    __sync_synchronize();  // memory barrier
    r->tail = next;
    return 0;
}

// dequeue (consumer — other VM)
static inline int
ivshmem_ring_dequeue(struct ivshmem_ring *r, void *data, uint32_t len)
{
    uint32_t head = r->head;
    if (head == r->tail) return -ENODATA;  // empty

    memcpy(data, &r->data[head * len], len);
    __sync_synchronize();  // memory barrier
    r->head = (head + 1) & r->mask;
    return 0;
}
```

> [!note] 为什么不用 rte_ring？
> `rte_ring` 本身可以放在 IVSHMEM 共享内存中，但初始化需要 DPDK EAL 环境。如果 VM 里已经跑着 DPDK 应用，直接用 `rte_ring_create()` + 手动设置共享内存地址也可以。如果不想依赖 DPDK，用上面的自定义 ring 即可。

### 5.3 完整示例：VM0 发送，VM1 接收

**共享内存布局（所有 VM 提前约定好）：**

```
┌──────────────────────────────────────────────┐
│  offset 0x0000: Ring VM1→VM0 (4096 bytes)    │
│  offset 0x1000: Ring VM0→VM1 (4096 bytes)    │
│  offset 0x2000: Ring VM0→VM2 (4096 bytes)    │
│  offset 0x3000: Ring VM2→VM0 (4096 bytes)    │
│  ...                                         │
│  offset 0x8000: Payload data area             │
│  (可变长度消息的实际数据)                       │
└──────────────────────────────────────────────┘
```

**VM0 (sender)：**

```c
int main(void)
{
    struct ivshmem_ctx ctx;
    ivshmem_init(&ctx);

    // VM0→VM1 ring at offset 0x1000
    struct ivshmem_ring *tx_ring =
        ivshmem_ring_init((char *)ctx.bar2 + 0x1000);

    // payload area at offset 0x8000
    char *payload = (char *)ctx.bar2 + 0x8000;

    struct msg {
        uint32_t type;
        uint32_t payload_len;
    } msg;

    msg.type = 1;
    msg.payload_len = snprintf(payload, 4096,
                               "Hello from VM0 (id=%d)!", ctx.vm_id);

    while (ivshmem_ring_enqueue(tx_ring, &msg, sizeof(msg)) != 0)
        ;  // spin until space available

    // notify VM1 via doorbell
    ivshmem_notify(&ctx, /*target=*/ 1);
    printf("Sent to VM1\n");
    return 0;
}
```

**VM1 (receiver)：**

```c
#include <signal.h>
static volatile int g_running = 1;
static void sigint_handler(int sig) { (void)sig; g_running = 0; }

int main(void)
{
    signal(SIGINT, sigint_handler);
    struct ivshmem_ctx ctx;
    ivshmem_init(&ctx);

    // VM0→VM1 ring at offset 0x1000
    struct ivshmem_ring *rx_ring =
        ivshmem_ring_init((char *)ctx.bar2 + 0x1000);

    char *payload = (char *)ctx.bar2 + 0x8000;

    printf("VM1 (id=%d) listening...\n", ctx.vm_id);

    while (g_running) {
        struct msg { uint32_t type; uint32_t payload_len; } msg;

        if (ivshmem_ring_dequeue(rx_ring, &msg, sizeof(msg)) == 0) {
            printf("Got: type=%u, data=%.*s\n",
                   msg.type, msg.payload_len, payload);
        } else {
            usleep(100);  // poll interval
        }
    }
    return 0;
}
```

### 5.4 Doorbell 中断 vs 轮询

```c
// 方案 A: 轮询 (无需内核驱动，最简单)
while (1) {
    if (ivshmem_ring_dequeue(ring, &msg, sizeof(msg)) == 0)
        handle_message(&msg);
    else
        usleep(100);  // or busy-wait for lower latency
}

// 方案 B: doorbell 中断 (需要 out-of-tree 驱动)
// 1. compile ivshmem-guest driver → /dev/ivshmem0
// 2. open() + mmap() to access BARs
// 3. read() blocks until doorbell fires
// 4. on interrupt: read() returns → process data → read() again
int fd = open("/dev/ivshmem0", O_RDWR);
while (1) {
    uint32_t doorbell_val;
    read(fd, &doorbell_val, sizeof(doorbell_val));  // blocks
    // process all pending messages
    while (ivshmem_ring_dequeue(ring, &msg, sizeof(msg)) == 0)
        handle_message(&msg);
}
```

> [!tip] 选型建议
>
> - **开发调试**：用轮询（方案 A），简单且不需要编译驱动
> - **低延迟生产**：用 doorbell 中断（方案 B），避免轮询空转浪费 CPU
> - **超高吞吐**：批量处理 + 轮询，每次 dequeue 多条消息再统一处理

### 5.1 DPDK IVSHMEM 架构

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         DPDK IVSHMEM 架构                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐  │
│  │                     DPDK IVSHMEM Library                             │  │
│  │                                                                     │  │
│  │  ┌────────────────┐    ┌────────────────┐    ┌────────────────┐   │  │
│  │  │  rte_ivshmem   │    │   Protocol    │    │  ring/libring  │   │  │
│  │  │  Manager       │    │   Manager     │    │  (无锁环形缓冲) │   │  │
│  │  └────────┬───────┘    └────────┬───────┘    └────────┬───────┘   │  │
│  │           │                     │                     │            │  │
│  │           └─────────────────────┼─────────────────────┘            │  │
│  │                                 │                                      │  │
│  │                                 ▼                                      │  │
│  │  ┌───────────────────────────────────────────────────────────────┐   │  │
│  │  │              Shared Memory Region (IVSHMEM BAR)              │   │  │
│  │  │                                                               │   │  │
│  │  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐          │   │  │
│  │  │  │ rte_ring│  │ rte_ring│  │  mbuf   │  │  mbuf   │          │   │  │
│  │  │  │ (VM1→2) │  │ (VM2→1) │  │  pool   │  │  pool   │          │   │  │
│  │  │  └─────────┘  └─────────┘  └─────────┘  └─────────┘          │   │  │
│  │  │                                                               │   │  │
│  │  └───────────────────────────────────────────────────────────────┘   │  │
│  │                                                                     │  │
│  └─────────────────────────────────────────────────────────────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 IVSHMEM 管理器

```c
// lib/librte_eal/common/include/rte_ivshmem.h

// IVSHMEM 元数据
struct rte_ivshmem_metadata {
    int vm_id;                    // 当前 VM 的 ID
    int nbVMs;                    // 总 VM 数
    int peer_ids[RTE_MAX_VMS];    // 对端 VM IDs

    void *addr;                   // 共享内存地址
    uint64_t size;                // 共享内存大小
    uint64_t iova;                // 共享内存 IOVA

    // ring 指针数组
    struct rte_ring *send_rings[RTE_MAX_VMS];
    struct rte_ring *recv_rings[RTE_MAX_VMS];

    // mbuf 池
    struct rte_mempool *mbuf_pool;
};

// 初始化 IVSHMEM
int
rte_ivshmem_init(int vm_id, int nb_peer_vms)
{
    struct rte_ivshmem_metadata *meta;

    meta = rte_zmalloc("ivshmem_meta", sizeof(*meta), 0);
    if (!meta)
        return -1;

    // 打开 IVSHMEM 设备
    meta->fd = open("/dev/ivshmem0", O_RDWR);
    if (meta->fd < 0) {
        rte_free(meta);
        return -1;
    }

    // 获取共享内存信息
    struct ivshmem_info info;
    ioctl(meta->fd, IVSHMEM_GET_INFO, &info);

    // mmap 共享内存
    meta->addr = mmap(NULL, info.size, PROT_READ | PROT_WRITE,
                      MAP_SHARED, meta->fd, 0);
    meta->size = info.size;
    meta->iova = rte_mem_virt2iova(meta->addr);

    // 初始化 ring
    char ring_name[RTE_RING_NAMESIZE];
    for (int i = 0; i < nb_peer_vms; i++) {
        snprintf(ring_name, sizeof(ring_name), "send_to_vm%d", peer_ids[i]);
        meta->send_rings[i] = rte_ring_create(ring_name, 1024,
                                               SOCKET_ID_ANY,
                                               RING_F_SC_DEQ);
    }

    return 0;
}
```

### 5.3 DPDK ring 在 IVSHMEM 中的使用

```c
// IVSHMEM 中的 rte_ring (无锁设计)

// ring 结构 (放在共享内存中)
struct rte_ring_ivshmem {
    volatile uint32_t write_idx;   // 写索引
    volatile uint32_t read_idx;   // 读索引
    uint32_t size;                // ring 大小 (2 的幂)
    uint32_t mask;                // size - 1
    void *objs[];                // 对象指针数组
} __attribute__((aligned(RTE_CACHE_LINE_SIZE)));

// 无锁入队
static __rte_always_inline int
rte_ring_ivshmem_enqueue(struct rte_ring_ivshmem *r, void *obj)
{
    uint32_t prod_idx = r->write_idx;

    // 检查是否有空间
    if ((prod_idx - r->read_idx) >= r->size) {
        return -ENOBUFS;
    }

    // 写入对象
    r->objs[prod_idx & r->mask] = obj;

    // 内存屏障
    rte_smp_wmb();

    // 更新写索引
    r->write_idx = prod_idx + 1;

    return 0;
}

// 无锁出队
static __rte_always_inline void *
rte_ring_ivshmem_dequeue(struct rte_ring_ivshmem *r)
{
    uint32_t cons_idx = r->read_idx;

    // 检查是否有对象
    if (cons_idx == r->write_idx) {
        return NULL;
    }

    // 读取对象
    void *obj = r->objs[cons_idx & r->mask];

    // 内存屏障
    rte_smp_rmb();

    // 更新读索引
    r->read_idx = cons_idx + 1;

    return obj;
}
```

### 5.4 IVSHMEM mbuf 池

```c
// IVSHMEM 中的 mbuf 池 (零拷贝关键)

// mbuf 头 (固定长度)
struct rte_ivshmem_mbuf {
    struct rte_mbuf_ext_shared_info ext;  // 外部缓冲区信息

    // mbuf 元数据
    uint16_t buf_len;       // 缓冲区长度
    uint16_t data_off;      // 数据偏移
    uint32_t pkt_len;       // 包长度
    uint16_t refcnt;        // 引用计数

    // 指向共享内存中的数据
    void *buf_addr;
    rte_iova_t buf_iova;
} __attribute__((aligned(RTE_CACHE_LINE_SIZE)));

// 创建 IVSHMEM mbuf 池
struct rte_mempool *
rte_ivshmem_mempool_create(const char *name, unsigned n,
                           unsigned elt_size, unsigned cache_size,
                           void *shmem_addr, uint64_t shmem_iova)
{
    struct rte_mempool *mp;
    struct rte_ivshmem_mbuf *m;

    // 在共享内存中分配 mbuf 数组
    m = (struct rte_ivshmem_mbuf *)(shmem_addr + IVSHMEM_MBUF_OFFSET);

    // 初始化 mempool
    mp = rte_mempool_create(name, n, elt_size, cache_size,
                            0, NULL, NULL, NULL,
                            m, shmem_iova + IVSHMEM_MBUF_OFFSET,
                            SOCKET_ID_ANY, 0);

    // 预填充 free 链表
    for (unsigned i = 0; i < n - 1; i++) {
        m[i].next = &m[i + 1];
    }
    m[n - 1].next = NULL;

    return mp;
}

// 零拷贝 mbuf 引用共享内存数据
static struct rte_mbuf *
rte_ivshmem_mbuf_ref(const struct rte_ivshmem_mbuf *imb,
                     void *data, uint16_t len)
{
    struct rte_mbuf *m = rte_pktmbuf_alloc(mbuf_pool);

    // 直接引用共享内存中的数据区域
    m->buf_addr = data;
    m->buf_iova = rte_mem_virt2iova(data);
    m->data_off = 0;
    m->pkt_len = len;
    m->data_len = len;
    m->refcnt = 1;

    // 引用计数递增
    rte_mbuf_ext_refcnt_update(imb->ext, 1);

    return m;
}
```

---

## 6. 性能与优化

### 6.1 性能数据

> [!note] 数据来源
> 以下为典型量级参考，基于 IVSHMEM 相关论文和 QEMU 官方测试。实际性能取决于硬件、QEMU 版本、VM 数量等因素。

| 操作                           | 典型延迟  | 说明                        |
| ------------------------------ | --------- | --------------------------- |
| 共享内存读写                   | ~0.1 μs   | 直接访问，无 VMEXIT         |
| Doorbell 通知（含 VMEXIT）     | ~5-10 μs  | MMIO 写入 → QEMU → 中断注入 |
| 端到端（写数据 + 通知 + 处理） | ~5-15 μs  | 取决于通知方式和处理逻辑    |
| 大块数据传输 (1MB)             | ~10-50 μs | 共享内存带宽接近 PCIe 带宽  |

> [!important] 瓶颈在 doorbell，不在共享内存
> 共享内存读写本身极快（ns 级），但 doorbell 通知要经过 VMEXIT，延迟 ~5-10μs。如果对延迟不敏感，可以纯轮询（不用 doorbell），完全消除 VMEXIT 开销。

### 6.2 优化建议

| 优化项              | 说明               | 效果       |
| ------------------- | ------------------ | ---------- |
| **Cache line 对齐** | 数据结构对齐到 64B | 避免伪共享 |
| **批量处理**        | 一次处理多条消息   | 提升吞吐量 |
| **无锁算法**        | 使用 CAS 操作      | 减少锁竞争 |
| **预分配内存**      | 避免运行时分配     | 降低延迟   |
| **Doorbell 合并**   | 批量通知           | 减少中断   |

---

## 7. 限制与注意事项

### 7.1 IVSHMEM 限制

| 限制         | 说明                                         | 解决方案                          |
| ------------ | -------------------------------------------- | --------------------------------- |
| **VM 数量**  | vectors 参数决定中断向量数，不是 VM 数量限制 | vectors >= (VM 总数 - 1)          |
| **内存大小** | 共享内存受 Host 物理内存限制                 | 合理规划大小                      |
| **VM 迁移**  | 不支持 live migration                        | 禁用迁移                          |
| **故障隔离** | 一个 VM 崩溃可能污染共享数据                 | 使用 CRC/版本号/心跳检测          |
| **同步**     | 无内置同步机制                               | 使用无锁数据结构或自旋锁          |
| **DPDK 库**  | rte_ivshmem 已移除 (20.05)                   | 直接 mmap PCI BAR 或用自定义 ring |

### 7.2 与其他方案对比

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    VM 间通信方案选型                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  场景 1: 跨主机通信                                                        │
│  ───────────────────                                                       │
│  方案: vhost-user (TCP) / iSCSI / NFS                                      │
│  原因: 需要网络传输                                                        │
│                                                                             │
│  场景 2: 同主机低延迟消息                                                    │
│  ─────────────────────────                                                 │
│  方案: IVSHMEM (ring + doorbell)                                          │
│  原因: 零拷贝，超低延迟                                                     │
│                                                                             │
│  场景 3: 同主机高速存储                                                    │
│  ───────────────────────                                                   │
│  方案: vhost-scsi / virtio-blk                                             │
│  原因: 存储需要持久化和事务语义                                             │
│                                                                             │
│  场景 4: 需要内核网络栈                                                    │
│  ───────────────────────                                                   │
│  方案: KNI                                                                 │
│  原因: 可以使用 iptables, routing 等                                       │
│                                                                             │
│  场景 5: VM ↔ Host 高性能通信                                             │
│  ──────────────────────────                                                │
│  方案: vhost-user (Unix socket)                                           │
│  原因: QEMU 直接交互，最优性能                                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 8. 小结

本章核心要点：

1. **IVSHMEM 是什么**：同主机多 VM 之间共享一块物理内存的机制。每个 VM 通过 PCIe BAR 映射到同一块 Host 物理内存，数据读写零拷贝。

2. **三种变体的 BAR 布局不同**：`ivshmem-plain`（只有共享内存，无通知）、`ivshmem-doorbell`（IVPosition + Doorbell + 共享内存，推荐）、`ivshmem`（legacy，兼容旧版 QEMU）。

3. **寄存器极其简单**：ivshmem-doorbell 只有 BAR0（IVPosition，只读返回 VM ID）和 BAR1（Doorbell，写入值编码目标 VM ID 和向量号）。

4. **Doorbell 走 VMEXIT**：共享内存读写不经过 hypervisor，但 doorbell 通知是 MMIO 写入，触发 VMEXIT 由 QEMU 转发，延迟 ~5-10μs。端到端延迟不是 ~1μs。

5. **QEMU 配置**：通过 `memory-backend-file` + `ivshmem-plain` 或 `ivshmem-doorbell` 创建。`vectors` 参数是中断向量数（>= VM 总数 - 1），不是 VM 数量上限。

6. **Linux 没有主线 IVSHMEM 驱动**：需要 out-of-tree 模块（如 ivshmem-guest），或直接 mmap `/sys/bus/pci/devices/.../resource2` 访问 BAR2。

7. **DPDK IVSHMEM 库已移除**（20.05）：当前方案是直接 mmap PCI BAR + 自定义无锁 ring，不需要任何特殊库。

8. **限制**：不支持 live migration，故障隔离靠应用层，同步机制需自行实现。

**下一篇预告**：[[ch19-vdpa|第十九章]]将讲解 VDPA 数据面加速与驱动——virtio 数据面的硬件卸载。

---

> [!tip] 参考文献
>
> - "QEMU IVSHMEM 规范", https://github.com/qemu/qemu/blob/master/docs/specs/ivshmem-spec.txt
> - "QEMU IVSHMEM Wiki", https://wiki.qemu.org/Features/IVShmem
> - "LWN: IVSHMEM and VM inter-guest communication", https://lwn.net/Articles/500615/
> - "ivshmem-guest 驱动", https://github.com/ngrechanov/ivshmem-guest
