---
title: "VPP 深入探讨 ch17：VPP + Docker/CNI"
date: 2026-04-10 02:30:00
tags: [vpp, docker, cni, container, networking, kubernetes, multus, sriov]
description: "深入解析 VPP 与 Docker 集成：CNI 插件配置、容器网络、Multus CNI、VPP CNI 设计与性能"
---

# VPP 深入探讨 ch17：VPP + Docker/CNI

> [!abstract] 核心要点
> VPP 通过 CNI 提供高性能容器网络。本章深入解析 CNI 规范、VPP CNI 插件、容器网络架构与 Multus 集成。

## 1. CNI 概述

### 1.1 CNI (Container Network Interface)

```
CNI 是容器网络的标准接口：

┌─────────────────────────────────────────────────────────────┐
│                    CNI 角色                                 │
│                                                              │
│  Container Runtime (Docker/containerd):                    │
│  - 创建容器网络命名空间                                      │
│  - 调用 CNI 插件配置网络                                     │
│                                                              │
│  CNI Plugin:                                                │
│  - 添加网络接口                                             │
│  - 配置 IP 地址                                             │
│  - 设置 routes                                              │
│                                                              │
│  CNI Configuration:                                         │
│  - /etc/cni/net.d/*.conflist                              │
│  - /opt/cni/bin/*                                          │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 CNI 操作

```
CNI 插件需要实现：

ADD: 添加容器到网络
  - 创建 veth pair
  - 分配 IP
  - 配置 routes
  - 返回结果

DEL: 从网络移除容器
  - 删除 veth
  - 释放 IP

CHECK: 检查网络配置
  - 验证配置正确性

VERSION: 返回支持的 CNI 版本
```

## 2. VPP CNI 插件

### 2.1 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP CNI 架构                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │               VPP CNI Plugin                          │  │
│  │                                                       │  │
│  │  ADD:                                                    │  │
│  │    1. 调用 VPP API 创建接口                          │  │
│  │    2. 创建 veth pair                                 │  │
│  │    3. 一端连到 VPP                                   │  │
│  │    4. 另一端放到容器                                  │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    VPP                               │  │
│  │                                                       │  │
│  │  - L2 Bridge Domain                                  │  │
│  │  - L3 routing                                        │  │
│  │  - ACL/QoS                                           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VPP CNI 实现

```go
// VPP CNI main.go (伪代码)
package main

import (
    "github.com/containernetworking/cni/pkg/skel"
    "github.com/containernetworking/cni/pkg/types"
)

type NetConf struct {
    types.NetConf
    VppSocket string `json:"vpp_socket"`
    BridgeDomain string `json:"bridge_domain"`
    CIDR string `json:"cidr"`
}

func cmdAdd(args *skel.CmdArgs) error {
    // 1. 解析配置
    conf := &NetConf{}
    json.Unmarshal(args.StdinData, conf)

    // 2. 调用 VPP API
    vpp := NewVppClient(conf.VppSocket)

    // 3. 创建 VPP 接口
    ifName := "vpp" + args.ContainerID[:8]
    ip := allocateIP(conf.CIDR)

    vpp.CreateTap(ifName, ip)
    vpp.SetInterfaceUp(ifName)

    // 4. 创建 veth pair
    hostIfName := "veth" + args.ContainerID[:8]
    createVethPair(hostIfName, ifName)

    // 5. 移动到容器 netns
    moveInterfaceToNetns(hostIfName, args.Netns)

    // 6. 在容器内配置
    setupContainerInterface(ifName, ip, args.Netns)

    return types.PrintResult(result, CNIVersion)
}

func cmdDel(args *skel.CmdArgs) error {
    // 删除资源
    vpp.DeleteTap(ifName)
    freeIP(ip)
    return nil
}

func main() {
    skel.PluginMain(cmdAdd, cmdDel, cmdCheck, version)
}
```

### 2.3 VPP CNI 配置

```bash
# 安装 VPP CNI
cp vppcni /opt/cni/bin/
cp 10-vpp.conf /etc/cni/net.d/

# /etc/cni/net.d/10-vpp.conf
{
    "cniVersion": "0.3.1",
    "name": "vpp-network",
    "type": "vppcni",
    "vpp_socket": "/var/run/vpp/vpp-api.sock",
    "bridge_domain": "docker",
    "ipam": {
        "type": "host-local",
        "subnet": "10.10.0.0/16",
        "rangeStart": "10.10.1.1",
        "rangeEnd": "10.10.255.254"
    }
}
```

## 3. VPP TAP 连接到容器

### 3.1 TAP 设备

```
VPP 使用 TAP 设备连接容器：

┌─────────────────────────────────────────────────────────────┐
│                    TAP 连接架构                            │
│                                                              │
│  ┌────────────────┐    ┌────────────────┐                   │
│  │   Container    │    │      VPP       │                   │
│  │                │    │               │                   │
│  │  eth0          │    │   vpp TAP     │                   │
│  │  10.10.1.2     │◀───▶│   10.10.1.1   │                   │
│  │                │    │               │                   │
│  └───────┬────────┘    └───────┬────────┘                   │
│          │                     │                             │
│          │    veth pair       │                             │
│          └─────────────────────┘                             │
│                                                              │
│  数据包路径：                                                │
│  Container eth0 → veth → TAP → VPP → L2/L3 → NIC          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 TAP 创建

```bash
# 手动创建 TAP
vpp# create tap id 0
vpp# set interface ip addr tap0 10.10.1.1/24
vpp# set interface state tap0 up

# 查看 TAP
vpp# show tap

# 示例输出：
# TAP 0: enabled, active
#   MAC: aa:bb:cc:dd:ee:ff
#   IP: 10.10.1.1/24
```

## 4. Multus CNI

### 4.1 Multus 概述

```
Multus 允许容器多网络接口：

┌─────────────────────────────────────────────────────────────┐
│                    Multus CNI                              │
│                                                              │
│  Pod                                                       │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  eth0: 默认网络 (flannel/calico)                    │  │
│  │  net0: VPP 网络 (高性能)                            │  │
│  │  net1: SRIOV VF (硬件加速)                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Multus + VPP 配置

```bash
# 安装 Multus
kubectl apply -f multus.yaml

# 创建 VPP NetworkAttachmentDefinition
cat <<EOF | kubectl apply -f -
apiVersion: "k8s.cni.cncf.io/v1"
kind: NetworkAttachmentDefinition
metadata:
  name: vpp-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "vpp-network",
    "type": "vppcni",
    "vpp_socket": "/var/run/vpp/vpp-api.sock",
    "bridge_domain": "default"
  }'
EOF

# Pod 使用 VPP
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: mypod
  annotations:
    k8s.v1.cni.cncf.io/networks: vpp-network
spec:
  containers:
  - name: mypod
    image: nginx
EOF
```

## 5. 容器网络架构

### 5.1 单一 VPP 实例

```
单 VPP + 多容器：

┌─────────────────────────────────────────────────────────────┐
│                    VPP 实例                                 │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Bridge Domain: docker                               │  │
│  │                                                       │  │
│  │  tap0 ──────→ Container 1 (veth0)                   │  │
│  │  tap1 ──────→ Container 2 (veth1)                   │  │
│  │  tap2 ──────→ Container 3 (veth2)                   │  │
│  │  ...                                                 │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│                       VPP Forwarding                        │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 分布式 VPP

```
每节点 VPP + 跨节点 VXLAM：

┌─────────────────────┐    ┌─────────────────────┐
│     Node A          │    │      Node B          │
│ ┌─────────────────┐ │    │ ┌─────────────────┐ │
│ │ VPP              │ │    │ │ VPP              │ │
│ │  ├─ tap0 → C1    │ │    │ │  ├─ tap0 → C3   │ │
│ │  ├─ tap1 → C2    │ │    │ │  └─ tap1 → C4   │ │
│ │  └─ vxlan        │─┼────┼─┘  └─ vxlan        │ │
│ └─────────────────┘ │    │ └─────────────────┘ │
│                     │    │                      │
└─────────────────────┘    └─────────────────────┘
            ↓                          ↓
        Node A NIC              Node B NIC
```

## 6. VPP CNI 安装

### 6.1 手动安装

```bash
# 1. 安装 VPP CNI 二进制
cp vppcni /opt/cni/bin/vppcni
chmod +x /opt/cni/bin/vppcni

# 2. 创建 CNI 配置
cat > /etc/cni/net.d/10-vpp.conf <<'EOF'
{
    "cniVersion": "0.4.0",
    "name": "vpp",
    "type": "vppcni",
    "vppSocket": "/var/run/vpp/vpp-api.sock",
    "ipam": {
        "type": "host-local",
        "subnet": "10.10.0.0/16"
    }
}
EOF

# 3. 重启 containerd
systemctl restart containerd
```

### 6.2 验证

```bash
# 创建容器测试
docker run -it --rm --network=none alpine ip addr

# 连接容器到 VPP
# 需要手动调用 CNI 或使用网络驱动
```

## 7. 性能优化

### 7.1 批量操作

```go
// VPP CNI 批量操作优化
func batchCreateContainers(networks []NetworkConfig) error {
    reqs := make([]*api.ChannelRequest, len(networks))

    for i, n := range networks {
        req := &api.ChannelRequest{
            Type:   api.CreateTap,
            IfName: n.IfName,
            IP:     n.IP,
        }
        reqs[i] = req
    }

    // 批量发送到 VPP
    vpp.BatchSend(reqs)

    return nil
}
```

### 7.2 大页内存

```bash
# 配置大页用于 CNI
# /etc/vpp/startup.conf
buffers {
    default heap size 512M
}

# 容器使用大页
docker run --rm \
    --memory=1G \
    --memory-hugepages=1G \
    alpine
```

## 8. 总结

VPP CNI 架构：

```
Container Runtime
       ↓ CNI (ADD)
CNI Plugin (vppcni)
       ↓ API
VPP (Tap/vhost-user)
       ↓
Container (via veth)
```

CNI + VPP 优势：

| 特性 | 默认 Docker | VPP CNI |
|------|-------------|---------|
| **吞吐量** | ~2-3 Gbps | ~10-15 Gbps |
| **延迟** | ~100μs | ~10-30μs |
| **PPS** | ~500K | ~5-10M |
| **特性** | 基础网络 | ACL/QoS/隧道 |

Multus 集成允许 Pod 同时使用默认网络和 VPP 高性能网络。

---

## 参考资源

- [CNI 规范](https://github.com/containernetworking/cni/blob/master/SPEC.md)
- [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni)
- [VPP CNI Plugin](https://wiki.fd.io/view/VPP/CNI_Plugin)
