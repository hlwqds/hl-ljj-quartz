---
title: "ARM qemu 实验环境搭建踩坑记录"
date: 2026-07-30
description: "搭建 qemu vexpress-a9 + ARM 内核 + initramfs 实验环境过程中遇到的问题、根因定位过程和最终解决方案。"
tags: [linux-driver, qemu, arm, troubleshooting]
---

# ARM qemu 实验环境搭建踩坑记录

本文记录在搭建 1.5.1 节的 qemu vexpress-a9 实验环境时遇到的全部问题，以及每个问题的**实测证据**、**已排除项**、**最终结论**。目的是让后来者不重蹈覆辙。

一键搭建脚本：`scripts/setup-arm-env.sh`，已把下面所有修复内置。

---

## 问题一：Fedora 交叉工具链缺 ARM glibc headers

### 现象

BusyBox（用户态程序）交叉编译时报 `byteswap.h: 没有那个文件或目录`。

### 根因

Fedora 的 `gcc-arm-linux-gnu` 包只含编译器，**不含目标 glibc 的开发头文件**。这和 Debian 的 `gcc-arm-linux-gnueabihf`（自带完整 libc）不同。

### 解决

在 Debian 容器里编译 BusyBox（`podman run debian:bookworm`），利用 Debian 自带的 `gcc-arm-linux-gnueabihf` + glibc headers。内核不依赖 libc，用宿主机的 `arm-linux-gnu-gcc` 即可。

---

## 问题二：BusyBox applet 链接不全

### 现象

客户机 init 里 `mount`、`telnetd`、`login` 等命令 `not found`。

### 根因

BusyBox 是"一个二进制 + 一堆名字"的设计。`make install` 有时只生成部分 applet 链接（实测 103 个，而二进制支持 402 个）。只 `cp busybox` 不建链接，shell 的 PATH 查找找不到命令。

### 解决

用 `busybox --list` 获取完整 applet 列表，批量建全部 symlink：

```bash
qemu-arm-static ./busybox --list | while read app; do ln -sf busybox "$app"; done
```

> [!warning] 误删 busybox 实体
> 用 `rm -f [a-z]*` 清旧链接时会误删 `busybox` 二进制本身，导致全部 symlink 变死链。清链接时排除 busybox，或删后立即拷回。

---

## 问题三：IP 地址配错（qemu user 网络网段）

### 现象

telnet/SSH 连接 qemu hostfwd 转发的端口，TCP 握手成功（`Connected`）但随即断开（`Connection closed`）。

### 根因

init 里把 eth0 配成 `10.0.0.15`，但 qemu `-net user` 默认网段是 **`10.0.2.0/24`**，客户机默认 IP `10.0.2.15`，网关 `10.0.2.2`。IP 不在同一网段，hostfwd 转发的包到达客户机后无法被正确处理。

### 实测证据

```
客户机 ping 网关 10.0.2.2 → 3/3 收到（网络通）
宿主机 ping 客户机 10.0.2.15 → 0/2 收到（user NAT 模式下正常，宿主无路由）
宿主机 nc 经 hostfwd 连客户机 → 数据到达客户机 nc（已验证）
```

### 解决

init 里配 `ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up`。

> [!tip] qemu user 网络的特性
> `-net user` 是 NAT 模式，宿主机无法直接 ping 客户机 IP（没有路由）。宿主机只能通过 `hostfwd` 转发的 TCP 端口访问客户机。这不是 bug。

---

## 问题四：内核 CRNG 永不就绪

### 现象

- Dropbear SSH 握手超时（`Connection timed out during banner exchange`）
- busybox telnetd fork 的子进程被 SIGHUP 杀死（见问题六）
- 客户机日志无 `crng init done`，`entropy_avail` 始终为 0

### 根因

qemu 模拟环境没有物理硬件熵源（无磁盘抖动、无真实中断噪声）。内核的 CRNG（Cryptographically Secure Random Number Generator）需要收集足够熵才能初始化，在纯虚拟环境里这个过程可能耗时数十秒甚至永不完成。

### 实测证据

```
未加 virtio-rng:  crng init done @ 24.8s（偶尔），或永远不就绪
加 virtio-rng:    crng init done @ 0.59s（秒级就绪）
```

### 解决

1. 内核配置开 `CONFIG_HW_RANDOM_VIRTIO=y`（multi_v7_defconfig 默认 **未开**）
2. qemu 启动加 `-device virtio-rng-device`

```bash
# 内核
sed -i 's/# CONFIG_HW_RANDOM_VIRTIO is not set/CONFIG_HW_RANDOM_VIRTIO=y/' .config
make olddefconfig && make zImage dtbs

# qemu
-device virtio-rng-device
```

---

## 问题五：Dropbear 空口令认证被拒

### 现象

SSH 握手成功（host key 交换完成），但认证失败：`Permission denied (publickey,password)`。

### 根因

Dropbear 默认拒绝空口令登录（安全策略）。

### 解决

dropbear 启动加 `-B` 参数：`dropbear -E -B -p 22`（`-B` = allow blank password）。

---

## 问题六：Dropbear 运行时生成 host key 卡住

### 现象

init 里调 `dropbearkey -t rsa` 生成 host key，客户机串口卡在 `Waiting for kernel randomness to be initialised...`。

### 根因

RSA key 生成需要随机数，而 CRNG 未就绪（同问题四）。vexpress-a9 没有 RNDR 指令（ARM 的硬件随机数），`random.trust_cpu=on` 无效。

### 解决

在宿主机（容器里用 qemu-user-static）**预生成** host key，打进 initramfs，跳过运行时生成：

```bash
qemu-arm-static ./dropbearkey-arm-static -t rsa -f initramfs/etc/dropbear/dropbear_rsa_host_key -s 2048
```

---

## 问题七：Dropbear `/root` 目录权限检查

### 现象

SSH 握手 + 认证都通过，但 dropbear 日志报 `/root must be owned by user or root, and not writable by group or others`，连接断开。

### 根因

Dropbear 的安全检查要求登录用户的 home 目录权限正确（不能 group writable）。initramfs 里 `/root` 默认权限不符合。

### 解决

`chmod 700 initramfs/root`（打包前）。

---

## 问题八：telnetd 管道式测试误判为不可用（已解决）

### 现象

busybox `telnetd -l /bin/sh` 正常监听 23 端口，但用管道式客户端测试时连接立即关闭：

```bash
# 错误的测试方式：发完命令 stdin 立即 EOF
printf 'id\r\n' | telnet 127.0.0.1 5556   # → Connection closed by foreign host
```

### 根因

**不是 telnetd 的问题，是测试客户端的问题。**

管道式客户端（`printf ... | telnet`）发完数据后 stdin 立即 EOF，telnet 客户端关闭连接。telnetd 父进程检测到 socket 关闭 → 关闭 pty master → 内核按正常终端清理流程给前台进程组（shell 子进程）发 **SIGHUP** → shell 被杀。这是完全正常的终端行为（SSH 退出时也一样）。

### 诊断过程（strace 确认）

ARM 静态 strace 跟踪 telnetd fork 子进程（CRNG 已就绪环境），关键正向证据：

```
setsid()                                 = 0     ← 成功创建新会话
open("/dev/pts/0", O_RDWR)               = 0     ← 成功打开 slave pty 作 ctty
dup2(0, 1) / dup2(0, 2)                          ← 成功 dup 到 stdout/stderr
execve("/bin/sh", ...)                   = 0     ← shell 启动成功
```

**fork/pty/exec 路径全部正常。** SIGHUP 只在父进程关闭 socket 后出现：

```
父进程 close(5)    ← 检测到客户端 EOF，关闭 socket
子进程 --- SIGHUP {si_code=SI_KERNEL} ---    ← 内核清理前台进程组
子进程 +++ killed by SIGHUP +++
```

之前误以为是 vfork+pty 缺陷，经 strace 证实**不是**。

### 解决

用 `expect`（或交互式终端）保持连接，等响应后再退出：

```bash
# 正确的测试方式：expect 保持会话
expect -c '
  spawn telnet 127.0.0.1 5556
  expect -re "# *$"
  send "id\r"
  expect -re "uid=0"
  send "exit\r"
  expect eof
'
```

### 结论

| 维度 | 状态 |
| --- | --- |
| telnetd 本身 | ✅ 正常工作（fork/pty/exec 全部成功，strace 确认） |
| 管道式客户端 | ❌ EOF 过早断连，触发正常 SIGHUP 清理 |
| expect 客户端 | ✅ 验证通过（uid=0 root shell） |
| 验证脚本 | `scripts/verify-telnet.sh`（expect 驱动，rc=0） |
| 证据 | `lab/diag-state/evidence-telnet-success.log` |

### 诊断产物

归档在 `lab/diag-state/`：busybox 二进制、内核/busybox `.config`、strace trace、evidence-telnet-success.log。

---

## 问题九：vexpress-a9 无 PCI 总线

### 现象

尝试用 9p 共享目录（`virtio-9p-pci`）在宿主机和客户机间传文件，失败。

### 根因

vexpress-a9 是老式 machine，没有 PCI 总线（实测 `qemu-system-arm -M vexpress-a9 -device pci-testdev` → `No 'PCI' bus found`）。virtio-mmio transport 也不在默认设备树里。

### 解决

不依赖 9p，改用"重打 initramfs"的方式传模块。后续章节会展开具体做法。

---

## 最终环境参数清单

成功搭建的实验环境，关键参数如下：

| 组件 | 参数 |
| --- | --- |
| qemu machine | `-M vexpress-a9 -smp 4 -m 512M` |
| 网卡 | `-net nic,model=lan9118`（唯一支持的型号） |
| 网络 | `-net user,hostfwd=tcp:127.0.0.1:5555-:22`（客户机 IP 10.0.2.15） |
| 随机数 | `-device virtio-rng-device`（必须） |
| 串口 | `-append "console=ttyAMA0"`（PL011，不是 ttyS0） |
| DTB 路径 | `arch/arm/boot/dts/arm/vexpress-v2p-ca9.dtb`（6.x 归入 arm/ 子目录） |
| 远程登录 | Dropbear SSH，`-B` 空口令 root |
| 内核必开配置 | `MODULES` `BLK_DEV_INITRD` `SMSC911X` `NET` `HW_RANDOM_VIRTIO` |
