---
title: 迈洛思网卡雷电拓展坞适配记录
date: 2026-04-12 00:00:00
tags: [network, mellanox, thunderbolt, linux]
description: 使用雷电拓展坞在笔记本上测试迈洛思(Mellanox)网卡的完整适配过程
---

# 迈洛思网卡雷电拓展坞适配记录

## 背景

通过雷电(Thunderbolt)拓展坞将 Mellanox 网卡连接到笔记本，用于开发和测试环境。

## 硬件清单

| 设备          | 型号/说明                                                        |
| ------------- | ---------------------------------------------------------------- |
| 笔记本        | ThinkPad T14p (21RU0000CD)，Intel Arrow Lake，Thunderbolt 4      |
| 雷电拓展坞    | 超算存储 · Thunderbolt 3/4 转 PCIe 扩展坞（~40Gbps）             |
| Mellanox 网卡 | MCX4121A-ACAT（ConnectX-4 Lx EN，双口 25GbE SFP28，PCIe 3.0 x8） |
| 光模块        | 待确认                                                           |

### 带宽限制说明

MCX4121A 原生 PCIe 3.0 x8 带宽约 **64Gbps**，雷电拓展坞实测提供 PCIe 3.0 x4 带宽约 **32Gbps**（Thunderbolt 3/4 上限）。双口均从 x8 降级为 x4：

|              | `52:00.0` (enp82s0f0np0)      | `52:00.1` (enp82s0f1np1)      |
| ------------ | ----------------------------- | ----------------------------- |
| PCIe 链路    | 8GT/s x4 (downgraded from x8) | 8GT/s x4 (downgraded from x8) |
| PCIe 带宽    | ~32Gbps                       | ~32Gbps                       |
| 以太网速率   | 25Gbps                        | 25Gbps                        |
| Equalization | Phase1 完成                   | Phase1 未完成（不影响功能）   |

25GbE 单口跑满约 25Gbps，x4 带宽足够覆盖。双口同时满载（50Gbps）会超过 32Gbps 上限，可能出现拥塞。

### MCX4121A-ACAT 关键参数

- 芯片：ConnectX-4 Lx (MT27710)
- 接口：2x SFP28（双口）
- 速率：10/25GbE
- PCIe：3.0 x8
- 支持：RoCE v1/v2、VXLAN、NVMe over Fabrics
- 固件工具：MFT (Mellanox Firmware Tools)

## 环境信息

- **系统**：Fedora 43
- **内核**：6.19.9-200.fc43.x86_64
- **架构**：x86_64

## 依赖安装

适配过程中需要安装的软件包：

```bash
# 雷电设备管理（查看/授权 Thunderbolt 外设）
sudo dnf install bolt

# Mellanox 固件管理工具（固件升级、网卡配置）
sudo dnf install mft

# 网络配置工具
sudo dnf install ethtool pciutils
```

| 包名     | 用途                                        |
| -------- | ------------------------------------------- |
| bolt     | Thunderbolt 设备管理和授权                  |
| mft      | Mellanox Firmware Tools，固件升级和网卡诊断 |
| ethtool  | 网卡参数查看和调整                          |
| pciutils | lspci 等 PCIe 设备查看工具                  |

## 适配过程

### 1. 硬件连接

拓展坞通过雷电 4 线缆连接到 ThinkPad T14p，拓展坞独立供电，Mellanox 网卡插入拓展坞 PCIe 插槽。

### 2. 系统识别

首次连接后通过 `lspci` 检查，未发现 Mellanox 网卡。进一步检查发现：

**USB 通道正常：** 拓展坞自带的 RTL8153 千兆网口、USB Hub 均被识别。

**PCIe 隧道未建立：** `boltctl list` 无输出，Thunderbolt 设备树中没有拓展坞节点。

**内核日志关键信息：**

```bash
sudo journalctl -k --no-pager | grep -i thunder
```

```text
thunderbolt 0-1: new device found, vendor=0xb8 device=0x2464
thunderbolt 0-1: USB4_TBT SSD Enclosure
thunderbolt 0-0:1.1: new retimer found, vendor=0x8087 device=0xd9c
# 约 10 秒后 ↓
thunderbolt 0-0:1.1: retimer disconnected
thunderbolt 0-1: device disconnected
```

**现象：** 拓展坞被内核识别为 `USB4_TBT SSD Enclosure`（ASMedia 174c:2464 桥接芯片），但 retimer 在连接约 10 秒后反复断开，PCIe 隧道无法稳定建立。

**解决后（enroll 成功）：**

```bash
$ lspci | grep -i mellanox
52:00.0 Ethernet controller: Mellanox Technologies MT27710 Family [ConnectX-4 Lx]
52:00.1 Ethernet controller: Mellanox Technologies MT27710 Family [ConnectX-4 Lx]
```

```bash
$ ip link show enp82s0f0np0
# Link up
$ ip link show enp82s0f1np1
# Link up
```

```bash
$ sudo dmesg | grep -i mlx5
mlx5_core 0000:52:00.0: firmware version: 14.29.1016
mlx5_core 0000:52:00.0 enp82s0f0np0: Link up
mlx5_core 0000:52:00.1: firmware version: 14.29.1016
mlx5_core 0000:52:00.1 enp82s0f1np1: Link up
# 注意第二个口带宽警告
mlx5_core 0000:52:00.1: 2.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x1 link
```

**识别结果：**

- 固件版本：14.29.1016
- 双口均 Link up，25Gbps
- 网卡接口：`enp82s0f0np0`（52:00.0）、`enp82s0f1np1`（52:00.1）
- 双口 PCIe 均为 8GT/s x4（从原生 x8 降级，Thunderbolt 带宽上限）
- 注意：dmesg 中 `52:00.1` 初始报告 PCIe x1 是瞬时状态，最终协商为 x4

### 3. 驱动安装

### 4. 网卡配置

### 5. 链路验证

### 6. 性能测试

## 排坑记录

### 问题 1：拓展坞 retimer 反复断连，PCIe 隧道无法建立

**现象：** 连接拓展坞后约 10 秒，Thunderbolt retimer 断开，Mellanox 网卡完全不可见。

**日志特征：**

```
thunderbolt 0-0:1.1: retimer disconnected
thunderbolt 0-1: device disconnected
```

**原因链：**

1. Thunderbolt 默认安全级别为 `user`，新设备需手动授权
2. 授权请求通过 D-Bus 发送到桌面环境（boltd → GNOME Shell / KDE Plasma 内置代理）
3. 本机使用 **niri**（Wayland 平铺 WM），没有 Thunderbolt 授权代理组件
4. 无人授权 → 超时 → 驱动拆除 PCIe 隧道 → 表现为 retimer disconnect
5. 设备物理层本身没问题，是授权超时导致逻辑层拆除

**Thunderbolt 安全级别说明：**

| 级别     | 行为                       | 适用场景         |
| -------- | -------------------------- | ---------------- |
| `none`   | 所有设备自动授权           | 服务器、受控环境 |
| `user`   | 新设备需手动授权           | 笔记本（默认）   |
| `secure` | 需授权 + 安全连接验证      | 高安全要求       |
| `dponly` | 仅 Display Port，禁用 PCIe | 最严格           |

**检查命令：**

```bash
cat /sys/bus/thunderbolt/devices/domain*/security
boltctl list
echo $XDG_CURRENT_DESKTOP  # 检查桌面环境是否有 Thunderbolt 授权支持
```

**解决：** 用 `boltctl enroll --policy=auto` 永久信任设备，以后自动授权无需手动操作。

由于 10 秒窗口太短来不及手动执行，需要一个自动监控脚本：

```bash
#!/bin/bash
# 保存为 /tmp/tb-enroll.sh，设备出现后自动 enroll
while true; do
    uuids=$(boltctl list 2>/dev/null | grep -oP 'uuid:\s*\K\S+')
    for uuid in $uuids; do
        stored=$(boltctl list 2>/dev/null | grep -A20 "$uuid" | grep "stored:" | grep -v "no")
        if [ -z "$stored" ]; then
            echo "Enrolling $uuid ..."
            boltctl enroll --policy=auto "$uuid"
        fi
    done
    sleep 1
done
```

```bash
# 启动脚本，然后插上拓展坞
sudo bash /tmp/tb-enroll.sh
```

**enroll 成功后：**

```
 * USB4_TBT SSD Enclosure
   |- status:        authorized
   |- stored:        yes
      |- policy:     auto
```

设备被永久信任后，以后插拔不需要再授权， Mellanox 网卡直接被识别。

**备选方案（降低全局安全级别）：**

```bash
# 持久化内核参数，所有 Thunderbolt 设备免授权（安全性较低，不推荐）
sudo grubby --update-kernel=ALL --args="thunderbolt.security=none"
```

**注意：** 如果需要移除已信任的设备：

```bash
boltctl forget \<uuid\>
```

### niri 下 Thunderbolt 授权配置

GNOME 和 KDE 各自内置了 Thunderbolt 授权代理（弹窗确认），niri 等 wlroots 合成器没有对应的代理组件，目前也没有独立的第三方 Thunderbolt 授权 GUI。

**可用方案对比：**

| 方案                        | 安全性               | 操作复杂度     | 说明                           |
| --------------------------- | -------------------- | -------------- | ------------------------------ |
| 手动 `boltctl enroll`       | 高（按设备信任）     | 中             | 每个新设备手动跑一次           |
| systemd 自动 enroll 服务    | 中（自动信任新设备） | 低（一次配置） | 后台轮询，新设备自动 enroll    |
| `thunderbolt.security=none` | 低（免授权）         | 低             | 内核参数，全局生效，服务器常用 |

#### 方案 1：手动 enroll（推荐，已采用）

```bash
# 启动监控脚本，然后插上拓展坞
sudo bash /tmp/tb-enroll.sh
```

设备 enroll 后存入 `/var/lib/boltd/devices/`，以后插拔自动授权。

#### 方案 2：systemd 自动 enroll 服务

适用于经常接入不同雷电设备的场景，配置一次全自动：

**`/etc/systemd/system/bolt-auto-enroll.service`**

```ini
[Unit]
Description=Auto-enroll Thunderbolt devices with policy=auto
After=bolt.service
Requires=bolt.service

[Service]
Type=simple
ExecStart=/usr/local/bin/bolt-auto-enroll.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

**`/usr/local/bin/bolt-auto-enroll.sh`**

```bash
#!/bin/bash
# Watch boltctl and auto-enroll any new Thunderbolt device with policy=auto
while true; do
    uuids=$(boltctl list 2>/dev/null | grep -oP 'uuid:\s*\K\S+')
    for uuid in $uuids; do
        stored=$(boltctl list 2>/dev/null | grep -A20 "$uuid" | grep "stored:" | grep -v "no")
        if [ -z "$stored" ]; then
            boltctl enroll --policy=auto "$uuid" 2>&1 && \
                echo "$(date): Enrolled $uuid with policy=auto"
        fi
    done
    sleep 2
done
```

```bash
sudo chmod +x /usr/local/bin/bolt-auto-enroll.sh
sudo systemctl enable --now bolt-auto-enroll.service
```

#### 方案 3：全局免授权（服务器方案）

```bash
# 设置内核参数（需重启）
sudo grubby --update-kernel=ALL --args="thunderbolt.security=none"

# 恢复
sudo grubby --update-kernel=ALL --remove-args="thunderbolt.security=none"
```
