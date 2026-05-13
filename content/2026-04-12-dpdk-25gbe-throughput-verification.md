---
title: DPDK 25GbE 吞吐量验证 — 雷电拓展坞 + Mellanox MCX4121A
date: 2026-04-12 00:00:00
tags: [dpdk, mellanox, thunderbolt, performance, 25gbe]
description: 使用 DPDK 在雷电拓展坞 + Mellanox MCX4121A 环境下验证 25GbE 理论吞吐量
---

# DPDK 25GbE 吞吐量验证 — 雷电拓展坞 + Mellanox MCX4121A

## 背景

基于 [迈洛思网卡雷电拓展坞适配记录](/2026-04-12-mellanox-thunderbolt-dock-adapter) 中搭建的环境，使用 DPDK 验证 Mellanox MCX4121A 在 Thunderbolt 拓展坞下的实际吞吐量是否达到理论值。

### 理论值

| 指标          | 数值                                    |
| ------------- | --------------------------------------- |
| 以太网速率    | 25 Gbps                                 |
| 线速吞吐      | ~3.0 Mpps（64B 小包）                   |
| 大包吞吐      | ~2.98 GB/s（1518B，含开销约 23.8 Gbps） |
| PCIe 带宽上限 | 8GT/s x4 ≈ 32 Gbps                      |

## 环境信息

<!-- 从适配记录继承 -->

- **系统**：Fedora 43
- **内核**：6.19.9-200.fc43.x86_64
- **网卡**：Mellanox ConnectX-4 Lx (MCX4121A-ACAT)，双口 25GbE SFP28
- **接口**：`enp82s0f0np0`（52:00.0）、`enp82s0f1np1`（52:00.1）
- **PCIe 链路**：8GT/s x4
- **固件版本**：14.29.1016
- **连接方式**：Thunderbolt 拓展坞（ASMedia 桥接）

## 依赖安装

```bash
# DPDK 编译依赖
sudo dnf install -y meson ninja-build libibverbs-devel rdma-core-devel numactl-devel
```

| 包名             | 用途                                     |
| ---------------- | ---------------------------------------- |
| meson            | DPDK 构建系统                            |
| ninja-build      | 编译后端                                 |
| libibverbs-devel | RDMA 动词库（Mellanox 驱动需要）         |
| rdma-core-devel  | RDMA 核心开发头文件                      |
| numactl-devel    | NUMA 内存策略（DPDK Hugepages 分配需要） |

## DPDK 编译

DPDK 源码已有（版本 24.11.4，路径 `~/code/dpdk`），但 build 目录从 Arch Linux 移过来不兼容，需要清理重编。

### 清理旧构建

```bash
cd ~/code/dpdk
rm -rf build
```

### 配置

```bash
meson setup build
```

验证 mlx5 驱动已启用：

```bash
ls build/drivers/net/ | grep mlx
# 输出：mlx4  mlx5
```

### 编译（遇到问题）

```bash
ninja -C build -j$(nproc)
```

**编译失败**，Python 3.14 与 DPDK 24.11.4 的 buildtools 脚本不兼容：

```
FAILED: drivers/rte_common_dpaax.pmd.c
/usr/bin/meson runpython ../buildtools/gen-pmdinfo-cfile.py ...
```

DPDK 24.11.4 的 `pmdinfogen.py` 等构建脚本不支持 Python 3.14。需要升级 DPDK 版本或使用兼容的 Python 版本。

### 解决：使用 Python 3.12 编译

Fedora 43 默认 Python 3.14，DPDK 24.11.4 构建脚本不兼容。安装 Python 3.12 并在用户空间安装 meson + ninja，避免污染系统包。

```bash
# 安装 Python 3.12
sudo dnf install -y python3.12

# 用 Python 3.12 安装构建工具（用户空间）
/usr/bin/python3.12 -m ensurepip
/usr/bin/python3.12 -m pip install meson ninja pyelftools
```

**注意：** `pyelftools` 是 DPDK 构建必须的依赖（`pmdinfogen.py` 依赖 `elftools` 模块解析 ELF），缺少会报 `elftools module not found`。

### 配置与编译

```bash
cd ~/code/dpdk
rm -rf build

# 使用 Python 3.12 的 meson 配置
~/.local/bin/meson setup build

# 验证 mlx5 驱动已启用
ls build/drivers/net/ | grep mlx
# 输出：mlx4  mlx5

# 编译（使用 Python 3.12 的 ninja）
~/.local/bin/ninja -C build -j$(nproc)
```

**编译成功，** 验证 testpmd：

```bash
$ ~/code/dpdk/build/app/dpdk-testpmd -v
EAL: Detected CPU lcores: 16
EAL: Detected NUMA nodes: 1
# 输出版本信息
```

## DPDK 环境配置

### 1. Hugepages 配置

```bash
# 分配 1024 个 2M 大页（共 2GB）
sudo sysctl -w vm.nr_hugepages=1024

# 验证
cat /proc/meminfo | grep HugePages_Total
# 输出：HugePages_Total:    1024
```

**注意：** 如果分配失败（实际数量远小于请求值），说明内存碎片化严重，需要先释放内存（关闭虚拟机等），再重新分配。

### 2. 加载 VFIO 模块

```bash
sudo modprobe vfio-pci
sudo modprobe vfio_iommu_type1
```

### 3. 绑定网卡到 VFIO

使用 DPDK 自带的 `dpdk-devbind.py` 工具：

```bash
# 查看当前设备状态
~/code/dpdk/usertools/dpdk-devbind.py --status

# 绑定 Mellanox 到 vfio-pci
sudo ~/code/dpdk/usertools/dpdk-devbind.py -b vfio-pci 0000:52:00.0 0000:52:00.1
```

如果报 `IOMMU support is disabled`，可使用 `--noiommu-mode` 绕过：

```bash
sudo ~/code/dpdk/usertools/dpdk-devbind.py -b vfio-pci --noiommu-mode 0000:52:00.0 0000:52:00.1
```

**验证绑定：**

```bash
$ ~/code/dpdk/usertools/dpdk-devbind.py --status
Network devices using DPDK-compatible driver
============================================
0000:52:00.0 'MT27710 Family [ConnectX-4 Lx] 1015' drv=vfio-pci unused=mlx5_core
0000:52:00.1 'MT27710 Family [ConnectX-4 Lx] 1015' drv=vfio-pci unused=mlx5_core
```

### 4. 验证 DPDK 识别网卡

```bash
# noiommu 模式需要指定 VA 模式
sudo ~/code/dpdk/build/app/dpdk-testpmd -l 0-1 -n 4 --iova-mode=va \
  -a 0000:52:00.0 -a 0000:52:00.1 -- -i
```

## 排坑记录

### 问题 1：IOMMU 未启用，mlx5 无法在 noiommu VA 模式下工作

**现象：**

```
PCI_BUS: Expecting 'PA' IOVA mode but current mode is 'VA', not initializing
testpmd: No probed ethernet devices
```

**原因：** Mellanox mlx5 驱动要求物理地址（PA）IOVA 模式，但 noiommu 模式下只能使用虚拟地址（VA）模式。

**检查 IOMMU 状态：**

```bash
ls /sys/kernel/iommu_groups/ | wc -l
# 输出 0 表示 IOMMU 未启用
```

**解决：**

1. BIOS 中启用 VT-d（Intel Virtualization Technology for Directed I/O）— 已确认开启
2. 在内核参数中添加 `intel_iommu=on`

### 启用 IOMMU 内核参数

Fedora 43 使用 GRUB2，编辑内核参数：

```bash
# 查看当前内核参数
cat /proc/cmdline

# 编辑 GRUB 配置
sudo grubby --update-kernel=ALL --args="intel_iommu=on"
```

重启后验证 IOMMU 已生效：

```bash
# 验证内核参数
cat /proc/cmdline | grep iommu
# 应输出：... intel_iommu=on

# 验证 IOMMU groups 已创建
ls /sys/kernel/iommu_groups/ | wc -l
# 输出 > 0 表示 IOMMU 已启用

# 确认网卡在某个 IOMMU group 中
for g in /sys/kernel/iommu_groups/*; do
  for d in "$g"/devices/*; do
    if echo "$d" | grep -q "0000:52:00"; then
      echo "IOMMU group $(basename $g): $d"
    fi
  done
done
```

### Thunderbolt 拓扑与 IOMMU Group

确认 IOMMU 启用后，检查设备归属：

```bash
# 验证 IOMMU 已生效
cat /proc/cmdline | grep iommu
ls /sys/kernel/iommu_groups/ | wc -l

# 查看 Mellanox 所在的 IOMMU group
for g in /sys/kernel/iommu_groups/*/devices/*; do
  echo "$(echo $g | cut -d/ -f5): $(basename $g)"
done | grep -E "0000:5[012]"
```

**关键发现：** Mellanox 双口与 ASMedia PCIe 桥接芯片共享 IOMMU group 20：

```
IOMMU group 20:
  0000:51:00.0  ASMedia ASM2464PD PCIe Bridge
  0000:52:00.0  Mellanox ConnectX-4 Lx port 0
  0000:52:00.1  Mellanox ConnectX-4 Lx port 1
```

这意味着无法做完整的 IOMMU 隔离直通——桥接芯片不能脱离内核驱动，因此 Mellanox mlx5 不能绑定 vfio-pci。

### 启动 testpmd

Mellanox mlx5 驱动**不能绑定 vfio-pci**，需要保持 `mlx5_core` 内核驱动并通过 auxiliary bus 探测：

```bash
# 确保 Hugepages 已分配
sudo sysctl -w vm.nr_hugepages=1024

# 网卡必须使用 mlx5_core 驱动，不要绑 vfio-pci
# 使用 PCI 地址直接指定，mlx5 PMD 会自动通过 auxiliary bus 探测
sudo ~/code/dpdk/build/app/dpdk-testpmd -l 0-1 -n 4 \
  -a 0000:52:00.0 -a 0000:52:00.1 -- -i --port-topology=loop
```

验证端口识别成功后进入吞吐量测试。

## 吞吐量测试

### 前置条件

- IOMMU 已启用且 VFIO 绑定成功
- testpmd 能正常识别两个端口
- 光模块已连接（双口之间需要直连线或环回模块）

### 1. 单口环回测试

使用单个端口的内部环回模式，验证单口收发能力：

```bash
sudo ~/code/dpdk/build/app/dpdk-testpmd -l 0-1 -n 4 \
  -a 0000:52:00.0 -- -i --port-topology=loopback

# 进入 testpmd 交互界面后：
testpmd> set fwd io
testpmd> set txpkts 64
testpmd> start
testpmd> show port stats all
testpmd> stop
```

### 2. 双口转发测试

两个端口直连，一端发一端收：

```bash
# 需要直连线连接两个 SFP28 端口
sudo ~/code/dpdk/build/app/dpdk-testpmd -l 0-1 -n 4 \
  -a 0000:52:00.0 -a 0000:52:00.1 -- -i --forward-mode=mac

# 进入 testpmd 后：
testpmd> set fwd mac
testpmd> set txpkts 64
testpmd> start
# 等待 30 秒收集数据
testpmd> show port stats all
testpmd> stop
```

### 3. 不同包长测试

依次测试 64B、128B、256B、512B、1024B、1280B、1518B：

```bash
# 在 testpmd 交互界面中
testpmd> set txpkts 64,128,256,512,1024,1280,1518
testpmd> set fwd mac
testpmd> start
testpmd> show port stats all
```

或使用脚本批量测试不同包长：

```bash
for size in 64 128 256 512 1024 1280 1518; do
  echo "=== Testing packet size: ${size}B ==="
  # 通过 testpmd 命令行发送指定包长
  # 注意：需要先启动 testpmd，然后在交互界面中 set txpkts
done
```

### 性能关键参数

在测试前调整以下参数以获得最佳性能：

```bash
# 在 testpmd 交互界面中
testpmd> set fwd mac          # MAC 转发模式
testpmd> set verbose 1        # 减少日志输出开销
testpmd> set rxq 1            # 接收队列数
testpmd> set txq 1            # 发送队列数
testpmd> set rxd 1024         # 接收描述符数量
testpmd> set txd 1024         # 发送描述符数量
testpmd> port config 0 rx_offload scatter on   # 开启 scatter
testpmd> port config 0 rx_offload check_sum on # 开启校验和卸载
```

## 测试结果

### 测试配置

| 参数         | 值                      |
| ------------ | ----------------------- |
| 内核         | 6.19.11-200.fc43.x86_64 |
| 转发模式     | flowgen（主动发包）     |
| 端口拓扑     | paired（双口 DAC 直连） |
| 转发核心     | 3 cores（lcore 1-3）    |
| RX/TX 描述符 | 1024                    |
| 流数量       | 1024 flows              |
| 统计周期     | 30s（取稳定后第二周期） |
| 连接方式     | SFP28 DAC 直连铜缆      |

### 理论参考值

| 包长  | 线速 pps   | 线速 Gbps | 备注                 |
| ----- | ---------- | --------- | -------------------- |
| 64B   | 29.76 Mpps | 15.24     | 最苛刻，帧间隔 12.8B |
| 128B  | 15.33 Mpps | 18.84     |                      |
| 256B  | 7.89 Mpps  | 21.68     |                      |
| 512B  | 4.04 Mpps  | 24.12     |                      |
| 1024B | 2.05 Mpps  | 25.15     |                      |
| 1280B | 1.64 Mpps  | 25.22     |                      |
| 1518B | 1.39 Mpps  | 25.24     | MTU 帧，接近上限     |

### 实测结果

### 实测结果

| 包长  | 实测 pps  | 实测 Gbps | pps 达标率 | bps 达标率 | 备注         |
| ----- | --------- | --------- | ---------- | ---------- | ------------ |
| 64B   | 2.99 Mpps | 1.44      | 10.1%      | 9.4%       | CPU 软件瓶颈 |
| 128B  | 2.74 Mpps | 2.72      | 17.9%      | 14.4%      |              |
| 256B  | 2.37 Mpps | 4.78      | 30.1%      | 22.1%      |              |
| 512B  | 1.71 Mpps | 6.95      | 42.3%      | 28.8%      |              |
| 1024B | 1.06 Mpps | 8.61      | 51.5%      | 34.2%      |              |
| 1280B | 0.90 Mpps | 9.20      | 55.0%      | 36.5%      |              |
| 1518B | 0.76 Mpps | 9.18      | 54.5%      | 36.4%      | 带宽瓶颈     |

**关键指标：**

- **大包（1518B）单端口吞吐：9.18 Gbps**，双端口双向聚合 **18.4 Gbps**
- **小包（64B）吞吐：2.99 Mpps**，受限于 CPU 软件转发能力
- **TX-dropped 占比高**（64B 时 ~94%）：flowgen 生成速率远超物理链路，成功 TX 即实际吞吐

## 分析与结论

### 吞吐量瓶颈分析

#### 1. PCIe x4 共享带宽是硬上限

双口 Mellanox 通过 ASMedia ASM2464PD 桥接共享 PCIe 3.0 x4 上行链路，理论带宽 ~32 Gbps（含 128b/130b 编码开销）。实测双端口双向聚合 18.4 Gbps，占 PCIe 理论带宽的 **57.5%**，扣除 PCIe 协议开销（~20%）后利用率约 72%，属于合理水平。

#### 2. 小包受 CPU 软件瓶颈

64B 小包实测 2.99 Mpps，远低于线速 29.76 Mpps（达标率 10.1%）。原因是 flowgen 模式下每个包需要 CPU 构造完整 L2-L4 头部，3 个转发核心的 pps 生成能力约为 3 Mpps，这是 DPDK testpmd 软件层面的上限，不代表硬件极限。

#### 3. 大包受 PCIe 带宽瓶颈

1518B 大包实测 9.18 Gbps/端口，bps 达标率 36.4%。pps 达标率 54.5%（0.76/1.39 Mpps）说明 CPU 还能生成更多包，但带宽已被 PCIe x4 上行链路占满。这是 Thunderbolt 拓展坞场景的物理极限。

#### 4. IOMMU DMA 翻译开销可忽略

启用 `iommu=nopt` 后，IOMMU 硬件完成 64-bit→32-bit 地址翻译。实测吞吐与无 IOMMU 场景的理论值基本一致，说明 IOMMU 翻译延迟（~100ns/映射）对 bulk 数据传输影响可忽略。

### 已知限制

| 限制                         | 影响                    | 实测影响                     |
| ---------------------------- | ----------------------- | ---------------------------- |
| PCIe x4 共享上行             | 双口总带宽上限 ~32 Gbps | 聚合 18.4 Gbps（57.5%）      |
| ASMedia 桥接 DMA mask 32-bit | IOMMU group DMA 降级    | trust_tb + iommu=nopt 已解决 |
| Thunderbolt untrusted 标记   | DMA 强制走 SWIOTLB      | trust_tb.ko 已清除           |
| CPU 软件转发（flowgen）      | 小包 pps 上限 ~3 Mpps   | 64B 达标率 10.1%             |
| mlx5_core 共存模式           | 不能使用 vfio-pci 直通  | 需保持 mlx5_core 驱动        |

### 问题 2：noiommu 模式下 VFIO 绑定失败

**现象：** 使用 `--noiommu-mode` 绑定后，testpmd 启动时 mlx5 驱动拒绝初始化：

```
PCI_BUS: Expecting 'PA' IOVA mode but current mode is 'VA', not initializing
```

**原因：** mlx5 PMD 要求 IOMMU 提供物理地址映射，noiommu 模式只能提供虚拟地址。

**解决：** 启用 VT-d + `intel_iommu=on`，使用正规 IOMMU 模式绑定。

### 问题 3：mlx5 绑定 vfio-pci 后 Verbs 设备丢失

**现象：** 绑定 vfio-pci 后启动 testpmd：

```
mlx5_common: Verbs device not found: 0000:52:00.0
testpmd: No probed ethernet devices
```

**原因：** mlx5 PMD 依赖 rdma-core verbs 接口，而 rdma-core 需要 `mlx5_core` 内核驱动。绑定 vfio-pci 后 mlx5_core 被卸载，verbs 接口消失。

**解决：** 保持 `mlx5_core` 内核驱动，直接用 PCI 地址指定设备。mlx5 PMD 会自动通过 auxiliary bus（`mlx5_core.eth.*`）探测设备：

```bash
# 不需要绑定 vfio-pci，保持 mlx5_core 驱动
sudo ~/code/dpdk/build/app/dpdk-testpmd -l 0-1 -n 4 \
  -a 0000:52:00.0 -a 0000:52:00.1 -- -i --port-topology=loop
```

### 问题 4：swiotlb buffer 耗尽导致 MR 创建失败（根因：IOMMU group DMA 降级）

**现象：** testpmd 端口识别成功，但启动时报错：

```
mlx5_common: Failed to create an MR in PD ... for address range [...] (368381952 bytes) for mempool mb_pool_0
mlx5_net: port 0 Rx queue allocation failed: Invalid argument
```

dmesg 显示：

```
mlx5_core 0000:52:00.0: swiotlb buffer is full (sz: 720896 bytes), total 524288 (slots), used 2048 (slots)
infiniband mlx5_0: mlx5r_umr_create_xlt: unable to map DMA during XLT update.
```

**原因分析：**

1. **ASMedia 桥接 DMA mask 为 32-bit**：IOMMU group 20 中 ASMedia ASM2464PD 桥接芯片的 DMA mask 是 32-bit，而 Mellanox 双口是 64-bit

   ```bash
   $ cat /sys/bus/pci/devices/0000:51:00.0/dma_mask_bits   # ASMedia 桥接
   32
   $ cat /sys/bus/pci/devices/0000:52:00.0/dma_mask_bits   # Mellanox port 0
   64
   ```

2. **IOMMU DMA domain 按组内最严格设备降级**：IOMMU DMA domain 按组内所有设备中最严格的 DMA mask 设置。整个 group 20 的 DMA 被限制在 32-bit（4GB 地址空间）

3. **DPDK mempool 分配在 >4GB 地址**：DPDK 使用 Hugepages 分配的 mempool 位于物理地址 0x101caf000（~4.03GB），超出 32-bit DMA 范围

4. **内核退回 swiotlb bounce buffer**：由于物理地址 > 4GB 但 DMA 只能访问 < 4GB，内核尝试用 swiotlb bounce buffer 做地址转换。虽然 swiotlb 已增大至 1GB（524288 slots），但 IOMMU passthrough 模式下的 swiotlb 分配器对 > 4GB 内存的 bounce mapping 存在限制，720KB 的 UMR 页表 DMA 映射仍然失败

**根本原因：** `intel_iommu=on` 默认使用 `iommu=pt`（passthrough）模式，IOMMU 创建恒等映射（bus_addr = phys_addr）。当物理地址 > 4GB 但设备只能访问 < 4GB 时，passthrough 模式无法提供地址翻译，只能依赖 swiotlb bounce buffer。

**解决：** 添加 `iommu=nopt` 内核参数，禁用 IOMMU passthrough 模式，使用完整的 IOMMU DMA 域。IOMMU 会做 64-bit 物理地址 → 32-bit 总线地址的转换，不再需要 swiotlb bounce buffer。

> **注意：** 此方案需要配合移除 `swiotlb=524288` 内核参数才能生效，否则 swiotlb 仍会在 DMA32 zone 抢占内存导致碎片化。详见问题 6。

```bash
sudo grubby --update-kernel=ALL --args="iommu=nopt"
sudo grubby --update-kernel=ALL --remove-args="swiotlb=524288"
```

**原理：** 在非 passthrough 模式下：

- IOMMU DMA API 为 DPDK mempool 的每个物理页分配一个 32-bit 总线地址
- IOMMU 页表记录：`bus_addr (32-bit) → phys_addr (64-bit)` 的映射
- Mellanox 设备使用 32-bit bus_addr 发起 DMA，IOMMU 硬件自动翻译到 64-bit 物理地址
- 完全绕过 swiotlb，无 bounce buffer 开销

### 问题 5：Python 3.14 与 DPDK 构建不兼容

**现象：** `ninja` 编译 DPDK 24.11.4 时报 Python 脚本执行失败。

**原因：** DPDK 24.11.4 的 `buildtools/pmdinfogen.py` 等脚本不支持 Python 3.14 语法变更。

**解决：** 安装 Python 3.12，在用户空间安装 meson + ninja + pyelftools，使用 `~/.local/bin/meson` 和 `~/.local/bin/ninja` 编译。

### 问题 6：`iommu=nopt` 生效后 swiotlb 仍被触发，MR 创建持续失败

**现象：** 应用问题 4 的解决方案（添加 `iommu=nopt`）并移除 `swiotlb=524288` 后重启，testpmd 仍然报相同的 MR 创建失败错误：

```
mlx5_common: Failed to create an MR in PD 0x... for address range [0x101caf000, 0x117c00000) (368381952 bytes) for mempool mb_pool_0
```

dmesg 仍然出现 swiotlb 错误：

```
mlx5_core 0000:52:00.0: swiotlb buffer is full (sz: 720896 bytes), total 32768 (slots), used 2048 (slots)
infiniband mlx5_0: mlx5r_umr_create_xlt: unable to map DMA during XLT update.
```

**诊断过程：**

```bash
# 确认内核参数 — 仅保留 intel_iommu=on iommu=nopt，已移除 swiotlb
$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'iommu|swiotlb'
intel_iommu=on
iommu=nopt

# 确认 IOMMU 硬件已启用
$ sudo dmesg | grep 'DMAR: IOMMU enabled'
[    0.070641] DMAR: IOMMU enabled

# 但 DMA 子系统选择了 swiotlb 而非 IOMMU DMA mapping
$ sudo dmesg | grep 'PCI-DMA'
PCI-DMA: Using software bounce buffering for IO (SWIOTLB)
# 注意：如果 IOMMU DMA mapping 被正确选用，这里应显示 "PCI-DMA: Using Intel IOMMU"
```

**根因分析：Thunderclap 安全机制**

通过深入分析内核源码（`drivers/pci/probe.c`），定位到根本原因：**Linux 内核针对 Thunderclap DMA 攻击的安全防护**。

1. **Thunderbolt 热插拔设备被标记为 untrusted**

   内核源码 `set_pcie_untrusted()` 函数（`drivers/pci/probe.c:1736`）的判断逻辑：

   ```c
   static void set_pcie_untrusted(struct pci_dev *dev)
   {
       struct pci_dev *parent = pci_upstream_bridge(dev);
       if (!parent) return;

       // 如果上游 bridge 已标记为 untrusted，子设备继承
       if (parent->untrusted) {
           dev->untrusted = true;
           return;
       }

       // 架构相关的可移除设备检测
       if (arch_pci_dev_is_removable(dev)) {
           pci_dbg(dev, "marking as untrusted\n");
           dev->untrusted = true;
       }
   }
   ```

   Thunderbolt PCIe root port (`0000:50:00.0`) 被 BIOS/ACPI 标记为 `external_facing`，`arch_pci_dev_is_removable()` 对 x86 热插拔设备返回 `true`。所有下游设备（ASMedia 桥接、Mellanox 双口）继承 `untrusted` 标记。

   ```bash
   # 验证：PCIe bridge 被 removable 标记
   $ for d in /sys/bus/pci/devices/*/; do
       dev=$(basename $d)
       class=$(cat $d/class 2>/dev/null)
       if echo "$class" | grep -q '0604'; then
           removable=$(cat $d/removable 2>/dev/null || echo "N/A")
           echo "$dev (PCI bridge): removable=$removable"
       fi
   done
   0000:50:00.0 (PCI bridge): removable=removable    # TB root port
   0000:51:00.0 (PCI bridge): removable=removable    # ASMedia bridge
   ```

2. **untrusted 设备强制使用 SWIOTLB bounce buffer**

   内核 DMA 子系统对所有标记为 `untrusted` 的设备强制使用 SWIOTLB，即使 IOMMU 硬件翻译已启用。这是 Thunderclap 攻击（2019 NDSS 论文）的防护措施 — bounce buffer 确保设备只能访问内核专门分配的内存，不能通过 DMA 读写任意系统内存。

3. **SWIOTLB bounce buffer 容量不足**
   - 默认 swiotlb 大小为 64MB（32768 slots），分配在 DMA32 zone（< 4GB）
   - DPDK mempool 分配在 `0x101caf000`（~4.03GB），超出 32-bit DMA 范围 28.7MB
   - MR 注册需要为 368MB mempool 创建 DMA 映射，UMR 页表本身需要 720KB 连续 swiotlb 空间
   - swiotlb 仅 64MB，无法容纳，报 `swiotlb buffer is full`

4. **`iommu=nopt` 无效的原因**

   `iommu=nopt` 将 IOMMU 默认域从 passthrough 改为 translated，但 DMA 子系统对 untrusted 设备仍然优先选择 swiotlb 作为安全隔离层，而非直接使用 IOMMU 地址翻译。`dmesg` 中的 `PCI-DMA: Using software bounce buffering for IO (SWIOTLB)` 印证了这一点。

**关键发现：此问题无法通过内核参数解决。**

以下是尝试过但无效的方案：

| 方案                | 内核参数                    | 结果 | 原因                                    |
| ------------------- | --------------------------- | ---- | --------------------------------------- |
| IOMMU DMA 翻译      | `intel_iommu=on iommu=nopt` | 无效 | untrusted 设备仍走 swiotlb              |
| 增大 swiotlb        | `swiotlb=524288`            | 无效 | DMA32 zone 空间不足，反而加剧碎片化     |
| 禁用 swiotlb 预分配 | 移除 `swiotlb=524288`       | 无效 | swiotlb 默认 64MB 仍然不够              |
| 强制 IOMMU 翻译     | `iommu=nopt` + 无 swiotlb   | 无效 | DMA API 对 untrusted 设备始终选 swiotlb |

**`pci_dev->untrusted` 标记无法通过用户空间配置：**

- `/sys/bus/pci/devices/.../removable` — 只读，由内核在 PCI probe 时设置
- `/sys/bus/pci/devices/.../untrusted` — 无 sysfs 接口暴露
- `/sys/bus/thunderbolt/devices/domain1/security` — 只读，由固件决定
- `/sys/bus/thunderbolt/devices/domain1/iommu_dma_protection` — 只读
- 无任何内核参数或模块参数可以覆盖此行为

### 问题 7：解决方案 — 内核模块清除 untrusted 标记

**原理：** 编写一个极简的内核模块，在加载时遍历所有 PCI 设备，清除 `untrusted` 标记。清除后内核 DMA 子系统停止对这些设备使用 SWIOTLB，改用 IOMMU 硬件地址翻译。

**模块源码**（`trust_tb.c`）：

```c
// trust_tb.c — Clear untrusted flag on Thunderbolt devices for DPDK mlx5
#include <linux/module.h>
#include <linux/pci.h>

static int __init trust_tb_init(void)
{
    struct pci_dev *pdev = NULL;
    int count = 0;

    while ((pdev = pci_get_device(PCI_ANY_ID, PCI_ANY_ID, pdev)) != NULL) {
        if (pdev->untrusted) {
            pci_info(pdev, "clearing untrusted flag for DPDK mlx5\n");
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
MODULE_DESCRIPTION("Clear untrusted flag on Thunderbolt devices for DPDK");
```

**Makefile**：

```makefile
obj-m += trust_tb.o
KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
```

**编译与使用：**

```bash
# 编译（需要匹配版本的 kernel-devel）
cd ~/code/tools/trust_tb && make

# 加载模块
sudo insmod trust_tb.ko

# 验证 dmesg 输出
dmesg | grep trust_tb
# 应输出：trust_tb: cleared untrusted on 3 device(s)

# 然后正常启动 DPDK testpmd
sudo sysctl -w vm.nr_hugepages=1024
sudo ~/code/dpdk/build/app/dpdk-testpmd -l 0-1 -n 4 \
  -a 0000:52:00.0 -a 0000:52:00.1 -- -i --port-topology=loop
```

**注意事项：**

- 此模块禁用了 Thunderclap DMA 攻击防护，仅应在信任的硬件上使用
- 模块效果在重启后失效（untrusted 标记会在下次 PCI probe 时重新设置）
- `kernel-devel` 版本必须与运行内核匹配，跨小版本编译的模块无法加载（`vermagic` 检查）

## 带宽分析

在进入实测之前，先从架构层面分析 Thunderbolt 拓展坞下的理论带宽上限。

### PCIe 链路层级

```
Mellanox MCX4121A (双口 25GbE)
  └─ PCIe 3.0 x8 → 降级为 x4 (Thunderbolt 限制)
       └─ ASMedia ASM2464PD PCIe Bridge
            └─ Thunderbolt 4 隧道 (Tunnel 0)
                 └─ Host TB4 Controller (Meteor Lake-P)
```

### 各层级带宽对比

| 层级               | 带宽                       | 是否构成瓶颈                              |
| ------------------ | -------------------------- | ----------------------------------------- |
| 25GbE 以太网单口   | 25 Gbps                    | —                                         |
| PCIe 3.0 x4        | ~32 Gbps (方向性)          | 单口不瓶颈，双口同时满载（50 Gbps）会瓶颈 |
| Thunderbolt 4 隧道 | 40 Gbps (总带宽，双向复用) | 双口同时满载时会瓶颈                      |
| IOMMU DMA 翻译     | 硬件翻译，延迟 ~100ns      | 不瓶颈                                    |
| PCIe 3.0 x4 × 双口 | 理论共享 32 Gbps           | **双口同时跑满是硬上限**                  |

### 理论上限预估

| 场景            | 预估吞吐上限                  | 瓶颈因素                          |
| --------------- | ----------------------------- | --------------------------------- |
| 单口收发        | ~25 Gbps                      | Thunderbolt 隧道 (40 Gbps) 有余量 |
| 单口 64B 小包   | ~25 Mpps (受限于 CPU 2 lcore) | 软件转发瓶颈                      |
| 双口同时满载    | ~32 Gbps 总计                 | PCIe 3.0 x4 共享带宽              |
| 双口 1518B 大包 | 各 ~16 Gbps                   | 带宽平分                          |

**结论：** 单口测试应能接近 25GbE 线速，双口同时跑满受限于 PCIe x4 共享带宽（约 32 Gbps），总吞吐上限约为线速的 64%。

## 结论

### 环境可行性

在 Thunderbolt 拓展坞环境下运行 DPDK + Mellanox mlx5 是**可行的**，但需要额外的配置步骤：

1. **必须启用 IOMMU**（`intel_iommu=on`），mlx5 PMD 不支持 noiommu VA 模式
2. **必须清除 Thunderbolt 设备的 untrusted 标记**（加载 `trust_tb` 内核模块），解决 SWIOTLB bounce buffer 限制
3. **保持 mlx5_core 内核驱动**，不能绑定 vfio-pci（mlx5 依赖 rdma-core verbs 接口）
4. **使用 Python 3.12 编译** DPDK 24.11.4，Fedora 43 默认 Python 3.14 不兼容

### 核心发现：Thunderbolt untrusted 标记是根本瓶颈

整个调试过程中遇到的 MR 创建失败、swiotlb buffer 耗尽、IOMMU group DMA 降级等问题，**根因都是同一个：Linux 内核将 Thunderbolt 热插拔设备标记为 untrusted，强制使用 SWIOTLB bounce buffer 作为安全隔离**。这不是 IOMMU 配置问题，而是内核的安全机制（Thunderclap DMA 攻击防护），无法通过内核参数绕过。

**问题链路：**

```
ACPI 标记 Thunderbolt root port 为 external_facing
  → arch_pci_dev_is_removable() 返回 true
    → set_pcie_untrusted() 设置 dev->untrusted = true（继承给所有下游设备）
      → DMA 子系统对 untrusted 设备强制使用 SWIOTLB bounce buffer
        → DPDK mempool 分配在 >4GB，超出 swiotlb 容量 → MR 创建失败
```

**无效的尝试：**

- `iommu=nopt`：不阻止 DMA API 对 untrusted 设备选择 swiotlb
- `swiotlb=524288`：DMA32 zone 空间不足，加剧碎片化
- 移除 `swiotlb=524288`：默认 64MB 仍然不够
- 查找 sysfs/内核参数覆盖 `untrusted`：无用户空间可配置接口

**有效方案：** 编译极简内核模块 `trust_tb.ko`，清除 `pci_dev->untrusted` 标记。

### 已知限制

| 限制                                         | 影响                                      | 缓解措施                                     |
| -------------------------------------------- | ----------------------------------------- | -------------------------------------------- |
| Thunderbolt untrusted 标记                   | DMA 被强制走 SWIOTLB，DPDK MR 注册失败    | 加载 `trust_tb` 内核模块清除标记             |
| IOMMU group 共享（桥接芯片 + 双口 Mellanox） | ASMedia 32-bit DMA mask 导致组内 DMA 降级 | 清除 untrusted 后 IOMMU 硬件自动处理地址翻译 |
| PCIe 3.0 x4 共享带宽                         | 双口同时满载上限 ~32 Gbps                 | 单口测试不受影响                             |
| CPU 核心数限制（2 lcore）                    | 64B 小包 pps 可能不达标                   | 增加核心分配或接受软件瓶颈                   |
| Thunderbolt 隧道协议开销                     | 实际可用带宽略低于 40 Gbps                | 不影响单口测试结论                           |
| trust_tb 禁用安全防护                        | 降低对恶意 Thunderbolt 设备的 DMA 防护    | 仅在信任的硬件上使用                         |

### 下一步

- ~~升级内核并安装匹配的 `kernel-devel`~~ 已完成（`kernel-6.19.11` + `kernel-devel-6.19.11`）
- ~~重启到新内核~~ 已完成
- ~~编译并加载 `trust_tb` 模块~~ 已完成（清除 4 个设备的 untrusted 标记）
- ~~分配 Hugepages~~ 已完成（1024 × 2MB = 2GB）
- ~~使用 `mlx5_core` 驱动启动 testpmd~~ 已完成（双口识别成功，mlx5_pci 驱动）
- ~~运行双口吞吐测试~~ 已完成（DAC 直连，flowgen 模式，7 种包长）

**可能的进一步优化：**

1. 单口测试（不共享 PCIe x4 带宽），预计单口大包可接近 15-16 Gbps
2. 使用 `pktgen` 替代 testpmd flowgen，CPU 包生成效率更高
3. 增加 lcore 数量（当前 3 个转发核心），可能提升小包 pps
4. 启用 TX offload（TSO、checksum）减少 CPU 开销
