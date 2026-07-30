---
title: "RDMA 深度探索（三）：Soft-RoCE/RXE 实验环境搭建"
date: 2026-05-24
description: "使用 Soft-RoCE/RXE 在普通以太网环境中搭建 RDMA 学习实验环境，并通过 ibv_devices、ibv_devinfo、perftest 验证。"
tags: [rdma, series, roce, rxe, linux]
---

> [!info] RDMA 深度探索系列 0. [[2026-05-24-rdma-deep-dive-series-index|系列索引]] 2. [[2026-05-24-rdma-deep-dive-ch2-verbs-objects|第二章：verbs 对象模型]] 3. **第三章：Soft-RoCE/RXE 实验环境搭建** 4. [[2026-05-24-rdma-deep-dive-ch4-rc-qp-lifecycle|第四章：RC QP 生命周期]]

# RDMA 深度探索（三）：Soft-RoCE/RXE 实验环境搭建

没有真实 RDMA 网卡也可以学习 RDMA verbs。Linux 提供 RXE，也就是 Soft-RoCE，用软件模拟 RoCE 设备。它的性能不能代表硬件 RDMA，但足够用来理解 API、QP 状态机和内存注册。

## 1. 实验目标

本章目标不是追求性能，而是让下面命令能正常工作：

```bash
ibv_devices
ibv_devinfo
rdma link
ib_send_bw
```

只要这些工具能看到 RXE 设备，就可以继续写 verbs demo。

## 2. 安装工具

Ubuntu / Debian：

```bash
sudo apt update
sudo apt install -y rdma-core ibverbs-utils perftest
```

openEuler / RHEL / Fedora：

```bash
sudo dnf install -y rdma-core libibverbs-utils perftest
```

如果发行版包名略有不同，可以搜索：

```bash
dnf search rdma
apt search rdma-core
```

## 3. 加载 RXE 模块

先确认网卡名：

```bash
ip link show
```

假设用于实验的普通以太网卡是 `eth0`，加载 RXE：

```bash
sudo modprobe rdma_rxe
sudo rdma link add rxe0 type rxe netdev eth0
```

检查：

```bash
rdma link
ibv_devices
```

你应该能看到类似：

```text
device           node GUID
------           ----------------
rxe0             ...
```

如果要删除：

```bash
sudo rdma link delete rxe0
```

## 4. 单机还是双机

RDMA 最自然的实验方式是两台机器：

```text
host A <---- ethernet ----> host B
```

两台机器都创建 RXE 设备，然后用 perftest 互测。

如果只有一台机器，也可以做 loopback 类实验，但很多真实网络问题暴露不出来。建议至少准备两台虚拟机或两台物理机。

## 5. 使用 perftest 验证

在服务端运行：

```bash
ib_send_bw
```

在客户端运行：

```bash
ib_send_bw 192.168.1.10
```

其中 `192.168.1.10` 是服务端普通网卡 IP。

再测试 RDMA Write：

```bash
ib_write_bw
```

客户端：

```bash
ib_write_bw 192.168.1.10
```

延迟测试：

```bash
ib_send_lat
ib_write_lat
```

RXE 的数值不会好看，重点是验证 verbs 路径可用。

## 6. GID 与 RoCE 的关系

RoCE 环境里，GID 表示 RDMA 端口上的全局标识。查看 GID：

```bash
show_gids
```

如果系统没有 `show_gids`，可以用：

```bash
ibv_devinfo -v
```

真实 RoCE v2 环境中，GID index 选错是很常见的问题。现象可能是设备存在、QP 创建成功，但通信失败。

入门阶段建议：

- 先用 perftest 自动选择。
- 程序里把 GID index 做成参数。
- 打印本地和远端 GID，避免交换错。

## 7. 常见问题

### 7.1 `ibv_devices` 看不到设备

检查模块：

```bash
lsmod | grep rxe
```

检查 RDMA link：

```bash
rdma link
```

确认你执行了：

```bash
sudo rdma link add rxe0 type rxe netdev eth0
```

### 7.2 `rdma link add` 失败

常见原因：

- 网卡名写错。
- 内核没有启用 RXE 模块。
- 当前用户权限不足。
- 容器环境缺少 RDMA 相关能力。

### 7.3 perftest 连接失败

排查顺序：

```text
1. 两端普通 IP 是否互通
2. 防火墙是否拦截
3. 两端是否都有 RDMA 设备
4. perftest 是否指定了正确设备和 GID
5. MTU 是否异常
```

可以先用：

```bash
ping 192.168.1.10
```

确认普通网络可达。

## 8. 本章小结

RXE 是学习 RDMA 的低成本入口。它不能代表硬件性能，但能覆盖 verbs 编程的大部分控制流程：

- 设备发现
- PD/MR/CQ/QP 创建
- QP 状态转换
- send/recv
- RDMA Read/Write
- CQ completion

下一章开始进入 RC QP 生命周期。只要理解 QP 如何从 RESET 走到 RTS，后面的 send/recv 和 RDMA Read/Write 就有了稳定骨架。
