---
title: DPDK + 25GbE on Thunderbolt — 完整踩坑与性能实测
date: 2026-04-12 00:00:00
tags: [dpdk, mellanox, thunderbolt, performance, 25gbe, iommu]
description: 在 Thunderbolt 拓展坞上跑 DPDK + Mellanox 25GbE 的完整方案，含 untrusted 标记、IOMMU DMA、swiotlb 的根因分析与吞吐量实测数据
---

# DPDK + 25GbE on Thunderbolt — 完整踩坑与性能实测

## 一句话结论

**Thunderbolt 拓展坞下跑 DPDK + Mellanox 25GbE 是可行的**，但需要编译内核模块清除 Linux 对 Thunderbolt 设备的 DMA 安全限制。双口聚合实测 **18.4 Gbps**，接近 TB4 标称带宽上限。

## 环境

| 项目 | 值 |
|------|-----|
| 系统 | Fedora 43，内核 6.19.11 |
| 网卡 | Mellanox ConnectX-4 Lx MCX4121A（双口 25GbE SFP28） |
| 拓展坞 | Thunderbolt 4，ASMedia ASM2464PD 桥接 |
| PCIe 链路 | 3.0 x4，共享双口上行 |
| DPDK | 24.11.4，Python 3.12 编译 |
| 连接 | SFP28 DAC 直连铜缆（双口互连） |

## 核心问题：Linux 拒绝让 Thunderbolt 设备做 DMA

DPDK 依赖用户态 DMA 直接读写网卡。但 Linux 内核（Thunderclap 攻击防护）会将 Thunderbolt 热插拔设备标记为 `untrusted`，强制所有 DMA 走 SWIOTLB bounce buffer。这个 buffer 默认只有 64MB，DPDK 的 mempool 分配在 >4GB 地址，直接溢出报错：

```
mlx5_common: Failed to create an MR ... (368381952 bytes) for mempool mb_pool_0
mlx5_core 0000:52:00.0: swiotlb buffer is full (sz: 720896 bytes)
```

**这个问题无法通过内核参数解决**（`iommu=nopt`、`swiotlb=524288` 均无效），因为 `pci_dev->untrusted` 标记没有用户空间可配置接口。

### 根因链路

```
ACPI 标记 TB root port 为 external_facing
  → arch_pci_dev_is_removable() 返回 true
    → set_pcie_untrusted() 设置 dev->untrusted = true（继承所有下游设备）
      → DMA 子系统强制走 SWIOTLB bounce buffer
        → DPDK mempool >4GB 超出 buffer 容量 → MR 创建失败
```

## 解决方案：编译 trust_tb 内核模块

15 行代码，清除所有 Thunderbolt 设备的 `untrusted` 标记：

```c
// trust_tb.c
#include <linux/module.h>
#include <linux/pci.h>

static int __init trust_tb_init(void)
{
    struct pci_dev *pdev = NULL;
    int count = 0;
    while ((pdev = pci_get_device(PCI_ANY_ID, PCI_ANY_ID, pdev)) != NULL) {
        if (pdev->untrusted) {
            pci_info(pdev, "clearing untrusted flag\n");
            pdev->untrusted = 0;
            count++;
        }
    }
    pr_info("trust_tb: cleared untrusted on %d device(s)\n", count);
    return 0;
}

static void __exit trust_tb_exit(void) {}
module_init(trust_tb_init);
module_exit(trust_tb_exit);
MODULE_LICENSE("GPL");
```

```makefile
obj-m += trust_tb.o
KDIR := /lib/modules/$(shell uname -r)/build
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
```

使用：

```bash
# kernel-devel 版本必须与运行内核匹配
make
sudo insmod trust_tb.ko
# dmesg: trust_tb: cleared untrusted on 4 device(s)
```

> 安全警告：此模块禁用了 Thunderclap DMA 攻击防护，仅在信任的硬件上使用。

## 完整启动流程

```bash
# 1. 内核参数（GRUB，需重启生效）
sudo grubby --update-kernel=ALL --args="intel_iommu=on iommu=nopt"

# 2. 重启后验证 IOMMU
ls /sys/kernel/iommu_groups/ | wc -l  # 应 > 0

# 3. 加载 trust_tb 模块
sudo insmod trust_tb.ko

# 4. 分配 Hugepages
sudo sysctl -w vm.nr_hugepages=1024  # 2GB

# 5. 启动 testpmd（保持 mlx5_core 驱动，不要绑 vfio-pci）
sudo dpdk-testpmd -l 0-3 -n 4 \
  -a 0000:52:00.0 -a 0000:52:00.1 \
  -- --forward-mode=flowgen --txpkts=1518 \
  --auto-start --disable-link-check --stats-period=10
```

### 其他踩坑

| 问题 | 原因 | 解决 |
|------|------|------|
| mlx5 要求 PA 模式但 noiommu 只有 VA | mlx5 PMD 需要 IOMMU 物理地址映射 | 启用 `intel_iommu=on` |
| 绑定 vfio-pci 后 Verbs 设备丢失 | mlx5 依赖 mlx5_core 内核驱动 | 不绑 vfio-pci，保持 mlx5_core |
| Python 3.14 编译 DPDK 失败 | pmdinfogen.py 不兼容 3.14 | 用 Python 3.12 编译 |
| kernel-devel 版本不匹配 | vermagic 检查 | `rpm -q kernel-devel-$(uname -r)` 确认一致 |

## 性能实测

flowgen 模式，双口 DAC 直连，3 个转发核心，每个包长跑 30s 取稳定值：

| 包长 | 实测 pps | 实测 Gbps | pps 达标率 | bps 达标率 |
|------|----------|-----------|-----------|-----------|
| 64B | 2.99 Mpps | 1.44 | 10.1% | 9.4% |
| 128B | 2.74 Mpps | 2.72 | 17.9% | 14.4% |
| 256B | 2.37 Mpps | 4.78 | 30.1% | 22.1% |
| 512B | 1.71 Mpps | 6.95 | 42.3% | 28.8% |
| 1024B | 1.06 Mpps | 8.61 | 51.5% | 34.2% |
| 1280B | 0.90 Mpps | 9.20 | 55.0% | 36.5% |
| 1518B | 0.76 Mpps | 9.18 | 54.5% | 36.4% |

### 关键数据

- **单端口大包：9.18 Gbps**（1518B）
- **双端口双向聚合：18.4 Gbps**
- **小包极限：~3 Mpps**（CPU 软件瓶颈，非硬件极限）

### 瓶颈分析

```
                    ┌─────────────────────┐
  25GbE 单口 ──────►│                     │
  (理论 25 Gbps)    │  Thunderbolt PCIe x4 │──── 主机
                    │  (实际 ~32 Gbps)     │
  25GbE 单口 ──────►│                     │
                    └─────────────────────┘
                         ↑ 瓶颈在这里
```

- **大包**：受 PCIe x4 共享带宽限制。双口 18.4 Gbps / PCIe 理论 32 Gbps = 57.5%，扣除协议开销后利用率约 72%，合理
- **小包**：受 CPU 软件包构造能力限制。flowgen 模式下 3 核心 ~3 Mpps，换 `pktgen` 可以更高
- **IOMMU 开销**：可忽略。`iommu=nopt` 硬件翻译对 bulk 传输无明显影响

### 能不能达到商家标称的 20Gbps？

**双口聚合 18.4 Gbps，基本达到标称值。** 如果做单口单向收发（不共享 PCIe），预计可到 15-16 Gbps。

## 总结

在 Thunderbolt 拓展坞下跑 DPDK + Mellanox 25GbE，技术上完全可行，但需要跨过 Linux 内核对 Thunderbolt DMA 的安全限制。核心发现是 `pci_dev->untrusted` 标记导致 SWIOTLB 强制启用，只能通过内核模块清除。性能方面，受 PCIe x4 共享上行带宽制约，双口聚合约 18 Gbps，适合开发调试和中等吞吐场景，不适合双口 25G 线速生产环境。

## 扩展阅读

- 详细的排坑过程记录：[DPDK 25GbE 吞吐量验证 — 雷电拓展坞 + Mellanox MCX4121A](/2026-04-12-dpdk-25gbe-throughput-verification)
- Thunderbolt 设备适配记录：[迈洛思网卡雷电拓展坞适配记录](/2026-04-12-mellanox-thunderbolt-dock-adapter)
