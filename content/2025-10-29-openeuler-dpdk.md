---
title: openeuler dpdk配置
date: 2025-10-29 00:11:00
pin: true
tags: [dpdk, net]
---


引用: https://blog.csdn.net/weixin_46261560/article/details/134922513

# openeuler dpdk配置

## 依赖


## 非root用户运行

https://stackoverflow.com/questions/66571932/can-you-run-dpdk-in-a-non-privileged-container-as-as-non-root-user/69178969#comment122283933_69178969

```bash
export XDG_RUNTIME_DIR=/tmp

mkdir -p /tmp/mnt/huge; sudo mount -t hugetlbfs nodev /tmp/mnt/huge
chown -R huanglin:huanglin /tmp/mnt/huge
lsmod | grep vfio
chowon -R huanglin:huanglin /dev/vfio/vfio

# app run with --huge-dir
./build/helloworld --iova-mode=va --huge-dir=/tmp/mnt/huge
```