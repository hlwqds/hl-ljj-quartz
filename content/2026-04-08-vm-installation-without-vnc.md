---
title: 虚拟机无 VNC 安装方案：纯文本全链路管理
date: 2026-04-08 00:00:00
tags: [vnc, libvirt, qemu, kvm, automation, kickstart]
---

# 虚拟机无 VNC 安装方案：纯文本全链路管理

> [!info] VNC 协议系列
>
> - [[2026-04-08-vnc-protocol-and-traffic-fingerprint|VNC 协议原理与流量特征分析]]
> - [[2026-04-08-vnc-framebuffer-reading-mechanism|VNC 帧缓冲区读取机制：物理机与虚拟机的差异]]
> - **虚拟机无 VNC 安装方案：纯文本全链路管理**（本文）

## 问题

Linux 发行版安装器通常提供图形界面，传统做法是通过 VNC 连接虚拟机手动操作。但 VNC 有明显缺陷：需要图形传输（带宽高）、需要额外端口暴露、在纯终端环境下不方便。

实际上，主流发行版都支持纯文本串口安装，可以完全不碰 VNC。

## 方案一：文本模式安装 + 自动应答文件

Linux 主流发行版支持通过串口进行文本模式安装，配合自动应答文件实现无人值守：

```bash
virt-install \
  --name vm1 \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --location /path/to/rhel-9.iso \
  --os-variant rhel9 \
  --console pty,target_type=serial \
  --extra-args "console=ttyS0,115200 inst.text inst.ks=http://10.0.0.1/ks.cfg"
```

核心启动参数：

| 参数                   | 作用                             |
| ---------------------- | -------------------------------- |
| `inst.text`            | 强制文本模式安装，不启动图形界面 |
| `console=ttyS0,115200` | 安装器输出重定向到串口           |
| `inst.ks=`             | 指向自动应答文件，全程无人值守   |

### 各发行版的应答文件方案

| 发行版             | 应答文件格式      | 引导参数         | 说明                         |
| ------------------ | ----------------- | ---------------- | ---------------------------- |
| RHEL/CentOS/Fedora | Kickstart (`.ks`) | `inst.ks=`       | Red Hat 系标准方案，功能最全 |
| Debian/Ubuntu      | Preseed (`.cfg`)  | `auto=true url=` | Debian 系标准方案            |
| openSUSE/SLES      | AutoYaST (`.xml`) | `autoyast=`      | SUSE 系标准方案              |
| Arch Linux         | 无安装器，脚本化  | pacstrap         | 直接用脚本构建系统           |
| Alpine             | answerfile        | `Answerfile=`    | 天然文本模式                 |

### Kickstart 示例（RHEL/CentOS/Fedora）

```kickstart
# ks.cfg - 全自动安装，不需要任何交互
text
lang en_US.UTF-8
keyboard us
network --bootproto=dhcp
timezone Asia/Shanghai
rootpw --plaintext yourpassword
bootloader --location=mbr
zerombr
clearpart --all --initlabel
autopart
selinux --enforcing
firewall --enabled --ssh
reboot

%packages
@core
vim
curl
git
%end
```

### Preseed 示例（Debian/Ubuntu）

```bash
virt-install \
  --name ubuntu-vm \
  --memory 2048 \
  --vcpus 2 \
  --disk size=20 \
  --location http://archive.ubuntu.com/ubuntu/dists/noble/main/installer-amd64/ \
  --os-variant ubuntu24.04 \
  --console pty,target_type=serial \
  --extra-args "console=ttyS0,115200 auto=true url=http://10.0.0.1/preseed.cfg priority=critical"
```

```bash
# preseed.cfg 核心配置
d-i debian-installer/locale string en_US.UTF-8
d-i keyboard-configuration/xkb-keymap select us
d-i netcfg/get_hostname string ubuntu-vm
d-i netcfg/get_domain string
d-i clock-setup/utc boolean true
d-i time/zone string Asia/Shanghai
d-i passwd/root-login boolean true
d-i passwd/root-password password yourpassword
d-i passwd/root-password-again password yourpassword
d-i partman-auto/method string regular
d-i partman-auto/choose_recipe select atomic
d-i partman-partitioning/confirm_write_new_label boolean true
d-i pkgsel/include string openssh-server vim curl git
d-i finish-install/reboot_in_progress note
```

安装过程中在串口看到的输出：

```
# virsh console vm1
Connected to domain vm1
...
: text mode installation starts
Setting up networking... done
Partitioning disks... done
Installing packages... ████████████████████ 100%
Performing post-installation... done
Installation complete. Rebooting...
```

全程不需要看图形界面。

## 方案二：Cloud Image + cloud-init（跳过安装）

连安装器都不跑，直接使用预构建的镜像：

```bash
# 下载 cloud image（已经装好的最小化系统）
wget https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2

# 用 virt-install 直接导入，不需要 ISO
virt-install \
  --name vm1 \
  --memory 2048 \
  --vcpus 2 \
  --disk path=centos9.qcloud2 \
  --import \
  --os-variant centos-stream-9 \
  --cloud-init user-data=cloud-init.cfg
```

cloud-init 配置：

```yaml
#cloud-config
hostname: vm1
users:
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - ssh-rsa AAAA... your-key
  - name: deploy
    sudo: ALL=(ALL) NOPASSWD:ALL
    ssh_authorized_keys:
      - ssh-rsa AAAA... your-key

# 可选：自动安装软件包
packages:
  - nginx
  - docker
  - vim

# 可选：自定义 systemd 服务
runcmd:
  - systemctl enable nginx
  - systemctl start nginx
```

启动后直接 SSH 进去，系统已经就绪，**安装时间为零**。

### 常用 Cloud Image 来源

| 发行版        | 下载地址                                                         |
| ------------- | ---------------------------------------------------------------- |
| CentOS Stream | https://cloud.centos.org/centos/                                 |
| Ubuntu        | https://cloud-images.ubuntu.com/                                 |
| Fedora        | https://kojipkgs.fedoraproject.org/compose/cloud/                |
| Debian        | https://cloud.debian.org/images/cloud/                           |
| Alpine        | https://alpinelinux.org/cloud/                                   |
| openSUSE      | https://download.opensuse.org/repositories/Cloud:/Images:/Leap_/ |

## 方案三：Packer 自动构建镜像

将方案一/二做成 CI/CD，版本化管理镜像：

```hcl
# packer.pkr.hcl
source "qemu" "rhel9" {
  iso_url           = "rhel-9.iso"
  iso_checksum      = "sha256:..."
  ssh_username      = "root"
  ssh_password      = "yourpassword"
  ssh_wait_timeout  = "30m"
  http_directory    = "."
  boot_command      = [
    "<up><wait>",
    "text inst.ks=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ks.cfg<enter>"
  ]
}

build {
  sources = ["source.qemu.rhel9"]

  provisioner "shell" {
    inline = [
      "yum install -y nginx docker git",
      "systemctl enable nginx docker"
    ]
  }

  provisioner "shell" {
    inline = [
      "sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config",
      "systemctl restart sshd"
    ]
  }
}
```

```bash
packer build packer.pkr.hcl
# 输出一个打包好的 qcow2，直接导入 libvirt 使用
```

Packer 的优势在于**镜像版本化**：每次构建产出固定哈希的镜像，可以回滚、可以复现、可以跨环境分发。

## TUI 工具的集成

[VirtUI Manager](https://github.com/aginies/virtui-manager) 已经集成了自动安装功能，内置各发行版的应答文件模板：

> Auto Installation: Support auto installation for Debian, Ubuntu, Fedora, Archlinux, Alpine, OpenSUSE and SLES

工作原理就是方案一 —— 用户在 TUI 中填几个参数（主机名、密码、网络），工具自动生成 Kickstart/Preseed 文件，通过串口完成安装，全程不弹 VNC。

同时它也提供 Web Console（noVNC + websockify）作为备用方案，在确实需要图形界面的场景下可以临时开启浏览器访问。

## 方案对比

| 方案                         | 需要 VNC？ | 自动化程度 | 安装时间 | 适用场景             |
| ---------------------------- | :--------: | :--------: | :------: | -------------------- |
| 图形安装器 + VNC             |     是     |     低     | 10-30min | 偶尔手动装一台       |
| 文本模式 + Kickstart/Preseed | **不需要** |     高     | 5-15min  | 批量部署，标准化配置 |
| Cloud Image + cloud-init     | **不需要** |    最高    |  < 1min  | 云环境，快速拉起     |
| Packer 构建                  | **不需要** |    最高    | 10-20min | CI/CD，版本化镜像    |

## 总结

VNC 装系统只是"默认最省事"的方式，不是唯一方式。配上自动应答文件 + 串口控制台，从装机到运维全链路都可以纯文本完成：

```
传统方式（依赖 VNC）：
  手动安装 → 图形界面 → 需要带宽 → 需要端口暴露 → 不方便自动化

纯文本方式（无 VNC）：
  应答文件 → 文本安装 → 串口控制台 → 极低带宽 → 完全可自动化
  或
  Cloud Image → cloud-init → 直接就绪 → 安装时间为零 → 完全可自动化
```
