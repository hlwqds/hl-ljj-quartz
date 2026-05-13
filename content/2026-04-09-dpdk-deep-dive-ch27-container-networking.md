---
title: "DPDK 深度探索 ch27：容器网络"
date: 2026-04-10 09:00:00
tags: [dpdk, container, docker, kubernetes, cni, vswitch, ovs-dpdk, polkit]
description: "深入解析 DPDK 容器网络：DOCKER/CNI、VSwitch、OVS-DPDK、Multus、Pod 网络与性能"
---

# DPDK 深度探索 ch27：容器网络

> [!abstract] 核心要点
> 容器网络需要高性能数据平面。本章深入解析 DPDK 在容器环境中的应用：OVS-DPDK、VSwitch、CNI 插件与 Kubernetes 网络。

## 1. 容器网络概述

### 1.1 容器网络模型

```
┌─────────────────────────────────────────────────────────────┐
│                    容器网络模型                              │
│                                                              │
│  Pod / Container                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  eth0 ←→ veth pair ←→ host eth0 ←→ physical NIC    │  │
│  │                     ↑                                 │  │
│  │              Linux Bridge / OVS                      │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                              │
│  问题：                                                     │
│  - veth pair 需要 kernel 处理                              │
│  - Bridge 学习/转发需要 CPU                               │
│  - 无法利用 DPDK 加速                                      │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 DPDK 容器网络优势

| 方案             | 吞吐量      | 延迟   | CPU 开销 |
| ---------------- | ----------- | ------ | -------- |
| **Linux Bridge** | ~2-3 Gbps   | ~100μs | 高       |
| **OVS (kernel)** | ~3-4 Gbps   | ~80μs  | 高       |
| **OVS-DPDK**     | ~10-15 Gbps | ~20μs  | 低       |
| **VPP**          | ~10-15 Gbps | ~15μs  | 低       |

## 2. OVS-DPDK

### 2.1 OVS-DPDK 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    OVS-DPDK 架构                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Open vSwitch (DPDK)                      │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │  Bridge  │  │  Port    │  │  Flow    │          │  │
│  │  │  Table   │  │  Table   │  │  Table   │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              DPDK (PMD + vhost-user)                  │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │  │
│  │  │  netdev  │  │  netdev │  │  netdev │          │  │
│  │  │  (dpdk)  │  │(vhost)  │  │(tap)    │          │  │
│  │  └──────────┘  └──────────┘  └──────────┘          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 OVS-DPDK 安装

```bash
# 安装 OVS-DPDK
apt-get install openvswitch-switch-dpdk

# 查看 DPDK 设备
ovs-dpdk-listen -c 0-3 -m 1024

# 查看大页
cat /proc/meminfo | grep Huge
# HugePages_Total:    512
# Hugepagesize:       2048 kB
```

### 2.3 OVS-DPDK 配置

```bash
# 初始化 OVS
ovs-vsctl set Open_vSwitch . other_config:dpdk-init=true
ovs-vsctl set Open_vSwitch . other_config:dpdk-lcore-mask=0xF
ovs-vsctl set Open_vSwitch . other_config:dpdk-huge-dir=/mnt/huge
ovs-vsctl set Open_vSwitch . other_config:pmd-cpu-mask=0xF

# 创建 Bridge
ovs-vsctl add-br br0 -- set Bridge br0 datapath_type=netdev

# 添加 DPDK 端口
ovs-vsctl add-port br0 dpdk0 -- set Interface dpdk0 \
    type=dpdk options:dpdk-devargs=0000:3d:00.0

# 查看端口
ovs-vsctl show

# 示例：
# Bridge br0
#     datapath_type: netdev
#     Port br0
#         Interface br0
#     Port "dpdk0"
#         Interface "dpdk0"
#             type: dpdk
```

## 3. Vhost-user Container 连接

### 3.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Vhost-user 容器连接                      │
│                                                              │
│  Container A         Container B                            │
│  ┌──────────┐        ┌──────────┐                            │
│  │  App     │        │  App     │                            │
│  │ + VPP    │        │ + VPP    │                            │
│  └────┬─────┘        └────┬─────┘                            │
│       │ vhost-user        │ vhost-user                      │
│       └────────┬───────────┘                                 │
│                ↓                                             │
│        ┌───────────────┐                                     │
│        │  OVS-DPDK     │                                     │
│        │               │                                     │
│        │  +---------+  │                                     │
│        │  | Flow    |  │                                     │
│        │  | Table   |  │                                     │
│        │  +---------+  │                                     │
│        └───────┬───────┘                                     │
│                ↓                                             │
│        Physical NIC                                          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 容器网络配置

```bash
# 创建 vhost-user 端口
ovs-vsctl add-port br0 vhost-client1 -- \
    set Interface vhost-client1 \
    type=dpdkvhostuserclient \
    options:vhost-client-path=/var/run/vpp/c1.sock \
    options:vhost-client-reconnect-interval=1000

# 或服务端模式
ovs-vsctl add-port br0 vhost-server1 -- \
    set Interface vhost-server1 \
    type=dpdkvhostuser \
    options:vhost-sock-path=/var/run/vpp/c1.sock

# 查看端口状态
ovs-vsctl show
ovs-ofctl show br0
```

### 3.3 VPP 容器网络

```bash
# VPP 侧创建 vhost-user socket
vpp# create vhost-user socket /var/run/vpp/c1.sock

# 配置 VPP
vpp# set interface ip addr vhost-client1 10.0.0.1/24
vpp# set interface state vhost-client1 up

# 连接到 OVS
ovs-vsctl add-port br0 vhost-server1 -- \
    set Interface vhost-server1 \
    type=dpdkvhostuser \
    options:vhost-sock-path=/var/run/vpp/c1.sock
```

## 4. CNI 插件

### 4.1 CNI 概述

```
Container Network Interface (CNI):

┌─────────────────────────────────────────────────────────────┐
│                    CNI 流程                                 │
│                                                              │
│  Container Runtime → CNI Plugin → Network                  │
│                                                              │
│  ADD: 创建网络接口 + 配置 IP                               │
│  DEL: 删除网络接口                                         │
│  CHECK: 检查配置                                            │
│  VERSION: 返回版本                                          │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 DPDK CNI 插件

```go
// dpdkcni/main.go
package main

import (
    "github.com/containernetworking/cni/pkg/skel"
    "github.com/containernetworking/cni/pkg/types"
)

type NetConf struct {
    types.NetConf
    DatapathType string `json:"datapath_type"`
    DevArgs      string `json:"dev_args"`
}

func cmdAdd(args *skel.CmdArgs) error {
    // 1. 解析配置
    conf := &NetConf{}
    json.Unmarshal(args.StdinData, conf)

    // 2. 创建 OVS 端口
    ovsPort := "cni-" + args.ContainerID[:8]
    ovs-vsctl add-br br0 -- \
        add-port br0 ${ovsPort} -- \
        set Interface ${ovsPort} \
        type=dpdkvhostuser \
        options:vhost-sock-path=${args.Netns}/${ovsPort}.sock

    // 3. 配置网络命名空间
    ipam := allocateIP(conf.CIDR)
    ns, _ := netns.GetFromPath(args.Netns)
    ns.Do(func() {
        exec.Command("ip", "link", "set", "eth0", "master", ovsPort).Run()
        exec.Command("ip", "addr", "add", ipam, "dev", "eth0").Run()
        exec.Command("ip", "link", "set", "eth0", "up").Run()
    })

    return nil
}
```

### 4.3 CNI 配置

```json
// /etc/cni/net.d/10-dpdk.conf
{
  "cniVersion": "0.4.0",
  "name": "dpdk-network",
  "type": "dpdkcni",
  "datapath_type": "netdev",
  "dev_args": "0000:3d:00.0",
  "ipam": {
    "type": "host-local",
    "subnet": "10.10.0.0/16"
  }
}
```

## 5. Kubernetes 网络

### 5.1 Multus CNI

```
Multus 允许多网络接口：

┌─────────────────────────────────────────────────────────────┐
│                    Multus 多网络                            │
│                                                              │
│  Pod                                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  eth0: 默认网络 (flannel)                           │  │
│  │  net0: OVS-DPDK 网络 (DPDK)                         │  │
│  │  net1: SRIOV VF (HW offload)                        │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Multus + OVS 配置

```yaml
# network-attachment-definition.yaml
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: ovs-dpdk-net
spec:
  config: '{
      "type": "ovs-dpdk",
      "datapath_type": "netdev",
      "bridge": "br0"
  }'
---
apiVersion: v1
kind: Pod
metadata:
  name: dpdk-pod
  annotations:
    k8s.v1.cni.cncf.io/networks: ovs-dpdk-net
spec:
  containers:
  - name: dpdk-app
    image: dpdk-app:latest
    securityContext:
      privileged: true
    resources:
      limits:
        hugepages-2Mi: 1Gi
        intel.com/dpdk: '1'
```

### 5.3 DPDK 设备插件

```yaml
# dpdk-device-plugin.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dpdk-device-plugin
spec:
  selector:
    matchLabels:
      app: dpdk-device-plugin
  template:
    metadata:
      labels:
        app: dpdk-device-plugin
    spec:
      hostNetwork: true
      containers:
        - name: dpdk-plugin
          image: intel/dpdk-device-plugin:latest
          securityContext:
            privileged: true
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
            - name: hugepages
              mountPath: /mnt/hugepages
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
        - name: hugepages
          emptyDir:
            medium: HugePages
```

## 6. SR-IOV 容器

### 6.1 SR-IOV 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SR-IOV 容器网络                          │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               Physical Function (PF)                   │  │
│  │               (ovs-dpdk 管理)                        │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓         ↓         ↓                                │
│  ┌────────┐ ┌────────┐ ┌────────┐                            │
│  │  VF 0  │ │  VF 1  │ │  VF 2  │                            │
│  │(Pod A) │ │(Pod B) │ │(Pod C) │                            │
│  └────────┘ └────────┘ └────────┘                            │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 SR-IOV 配置

```bash
# 启用 SR-IOV
echo 4 > /sys/class/net/eth0/device/sriov_numvfs

# 配置 VF
ip link set eth0 vf 0 mac 00:11:22:33:44:55
ip link set eth0 vf 0 vlan 100

# 绑定到 DPDK
dpdk-devbind --bind=igb_uio eth0 vf 0
dpdk-devbind --bind=igb_uio eth0 vf 1
```

## 7. 性能对比

### 7.1 容器网络性能

| 方案              | 吞吐量   | 延迟   | CPU cycles/pkt |
| ----------------- | -------- | ------ | -------------- |
| **veth + bridge** | ~2 Gbps  | ~100μs | ~400           |
| **OVS (kernel)**  | ~3 Gbps  | ~80μs  | ~300           |
| **OVS-DPDK**      | ~10 Gbps | ~20μs  | ~50            |
| **SR-IOV**        | ~15 Gbps | ~5μs   | ~20            |

### 7.2 优化建议

```bash
# OVS-DPDK 优化参数
ovs-vsctl set Open_vSwitch . \
    other_config:dpdk-swd=c0 \
    other_config:pmd-cpu-mask=0xF

# 大页配置
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# CPU 隔离
isolcpus=0-3
```

## 8. 总结

容器网络技术对比：

```
┌─────────────────────────────────────────────────────────────┐
│                    容器网络演进                             │
│                                                              │
│  veth + Bridge → OVS (kernel) → OVS-DPDK → SR-IOV          │
│      ↓              ↓              ↓            ↓           │
│    2 Gbps         3 Gbps        10 Gbps      15 Gbps        │
│                                                              │
│  VPP 也可以作为容器网络数据平面                              │
└─────────────────────────────────────────────────────────────┘
```

选择建议：

| 场景         | 推荐方案      |
| ------------ | ------------- |
| **开发测试** | veth + bridge |
| **一般生产** | OVS (kernel)  |
| **高性能**   | OVS-DPDK      |
| **超高性能** | SR-IOV        |

---

## 参考资源

- [OVS-DPDK](https://www.openvswitch.org/support/dist-docs/ovs-vswitchd.dpdk.conf.5.txt)
- [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni)
- [DPDK CNI](https://github.com/intel-app/networking-cni)
