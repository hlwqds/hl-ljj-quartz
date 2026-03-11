---
title: openeuler配置dpdk编译环境
date: 2025-12-16 00:11:00
pin: true
description: openeuler配置dpdk编译环境
tags: [dpdk, environment, openeuler]
---


# openeuler配置dpdk编译环境

## 环境

```bash
dnf groupinstall -y "Development Tools"
dnf install -y meson
link /usr/bin/python3 /usr/bin/python
pip3 install pyelftools
dnf install -y numactl-devel

# 可选项
# ut依赖
dnf install -y libarchive-devel
# bpf依赖
dnf install -y elfutils-libelf-devel

# 查看内核是否支持
# >= 5.4
uname -r

# glibc >= 2.7
ldd --version

# 编译选项
zcat /proc/config.gz | grep HUGETLBFS

zcat /proc/config.gz | grep PROC_PAGE_MONITOR
zcat /proc/config.gz | grep HPET
zcat /proc/config.gz | grep HPET_MMAP

# 运行时预留大页内存
# 单node
echo 1024 >| /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# numa多node
echo 1024 >| /sys/devices/system/node/node0/hugepages/hugepages-2048kB/nr_hugepages
echo 1024 >| /sys/devices/system/node/node1/hugepages/hugepages-2048kB/nr_hugepages

# boot阶段预留大页内存，有助于防止碎片化
# 修改在GRUB_CMDLINE_LINUX
cat /etc/default/grub
grub2-mkconfig -o /boot/grub2/grub.cfg

# 默认2MB大页 hugepages=1024
# default_hugepagesz=1G hugepagesz=1G hugepages=4

# 如果有不止一个dpdk进程需要使用，则需要配置hugepage文件系统
mkdir /mnt/huge
mount -t hugetlbfs pagesize=1GB /mnt/huge
# /dev/hugepages, 系统默认会创建这个挂在点
```

## 编译

```bash
meson setup build
cd build
ninja
meson install
# redhat /usr/local/lib and /usr/local/lib64 should be added to a file in /etc/ld.so.conf.d/
touch /etc/ld.so.conf.d/dpdk.conf
# /usr/local/lib64
ldconfig
```

## 运行

```bash
# 加载vfio-pci驱动
modprobe vfio-pci
# 虚拟环境中iommu group设计混乱，直接使用noiommu，这可能会导致Error enabling MSI-X，使用轮询模式可忽略，使用中断提醒则可以换成igd_uio
modprobe vfio enable_unsage_noiommu_mode=1

# 虚拟机再增加一个vmnet3网卡下面还是报错
# cat /etc/default/grub
# pcie_acs_override实验环境，虚拟网卡在同一个iommu group，强制单独group
# intel_iommu=on pcie_acs_override=downstream,multifunction
# grub2-mkconfig -o /boot/grub2/grub.cfg

cd dpdk
# 查看网卡状态
./usertools/dpdk-devbind.py --status
# 绑定网卡到vfio-pci驱动
./usertools/dpdk-devbind.py --noiommu-mode --bind=vfio-pci 0000:02:02.0
./usertools/dpdk-devbind.py --noiommu-mode --bind=vfio-pci 0000:02:03.0
```

## 应用

### 编译

```bash
meson setup -Dexamples=all build
cd build
ninja
meson install
```
