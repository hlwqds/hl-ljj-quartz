---
title: "DPDK 第四十二章：云原生 DPDK：VPP、service mesh"
date: 2026-04-09 17:10:00
tags: [dpdk, cloud-native, vpp, service-mesh, kubernetes, microseg]
description: "深入解析云原生网络中的 DPDK：VPP、FD.io、Cilium service mesh、 Kata 容器与 DPDK 的融合部署"
---

# DPDK 第四十二章：云原生 DPDK：VPP、service mesh

> [!abstract] 核心要点
> 云原生环境对高性能网络的需求推动了 DPDK 与 VPP、service mesh 的深度集成。本章解析 VPP、FD.io 项目、Cilium 与 DPDK 的关系，以及在 Kubernetes 中部署 DPDK 应用的最佳实践。

## 1. VPP 概述

### 1.1 什么是 VPP

VPP (Vector Packet Processing) 是 Cisco 开源的高性能数据包处理框架：

- **Vector Processing**：批量处理包，而非逐包处理
- **Framework**：可插拔的插件架构
- **DPDK 集成**：原生支持 DPDK 作为数据面
- **FD.io 旗舰项目**：Linux Foundation 下属项目

### 1.2 VPP vs 传统 DPDK

| 特性 | VPP | 传统 DPDK |
|------|------|-----------|
| **编程模型** | Framework（节点图） | Library（裸 API） |
| **配置方式** | CLI/API/Config file | Code |
| **可扩展性** | 插件机制 | 重新编译 |
| **协议支持** | 丰富（GRE/VXLAN等） | 需要自己实现 |
| **适用场景** | 通用 vSwitch/Router | 专用应用 |

### 1.3 VPP 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      VPP Node Graph                         │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                     run ("node-name")                │   │
│  └─────────────────────────────────────────────────────┘   │
│                            │                               │
│            ┌───────────────┼───────────────┐              │
│            ▼               ▼               ▼              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │  ethernet   │  │   arp       │  │   ip4       │        │
│  │  - input    │  │   - lookup  │  │   - input   │        │
│  └─────────────┘  └─────────────┘  └─────────────┘        │
│          │               │               │                 │
│          ▼               ▼               ▼                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐        │
│  │  ip4-lookup │  │  ip4-lookup │  │  ip4-rewrite│        │
│  └─────────────┘  └─────────────┘  └─────────────┘        │
│          │                                              │    │
│          └──────────────────────────────────────────────┘    │
│                            │                               │
│                            ▼                               │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              dispatch node (output)                 │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 2. VPP 核心概念

### 2.1 Node

VPP 由多个 node 组成，每个 node 处理一类数据包：

```c
// VPP node 示例
static uword
my_node_fn(vlib_main_t *vm, vlib_node_runtime_t *node, vlib_frame_t *frame)
{
    // 处理 frame 中的所有包（vector）
    u32 n_packets = frame->n_packets;

    for (i = 0; i < n_packets; i++) {
        // 批量处理
        process_packet(buffer[i]);
    }

    return n_packets;  // 传递到下一节点
}

// 注册 node
VNET_FEATURE_INIT(my_node, static) = {
    .arc_name = "device-input",
    .node_name = "my-node",
    .runs_before = VNET_FEATURES("interface-output"),
};
```

### 2.2 Feature Arc

Feature arc 定义 node 之间的连接：

```
┌─────────────────────────────────────────────────────────────┐
│                    device-input arc                         │
│                                                              │
│  ┌───────┐    ┌───────┐    ┌───────┐    ┌───────┐          │
│  │ eth0  │───▶│ arp   │───▶│ ip4   │───▶│ip4-   │          │
│  │ .input│    │.input │    │.input │    │lookup │          │
│  └───┬───┘    └───────┘    └───────┘    └───┬───┘          │
│      │                                        │              │
│  ┌───▼───┐    ┌───────┐    ┌───────┐    ┌───▼───┐          │
│  │ eth1  │───▶│ arp   │───▶│ ip4   │───▶│        │          │
│  │ .input│    │.input │    │.input │    │  ...  │          │
│  └───────┘    └───────┘    └───────┘    └────────┘          │
└─────────────────────────────────────────────────────────────┘
```

### 2.3 Interface

VPP 支持多种接口类型：

| 类型 | 说明 |
|------|------|
| **Host Interface** | 绑定到物理网卡（DPDK） |
| **Tap/Geneve** | 虚拟以太接口 |
| **Vhost-user** | 连接 QEMU/KVM |
| **Af_packet** | 连接 Linux 端口 |
| **Loopback** | 本地回环 |
| **VXLAN** | VXLAN 隧道端点 |
| **GRE** | GRE 隧道 |

### 2.4 VPP CLI

```bash
# 连接到 VPP CLI
vppctl

# 查看接口
vpp# show interface
vpp# show hardware

# 配置 IP
vpp# set interface ip address GigabitEthernet0/8/0 192.168.1.1/24
vpp# set interface state GigabitEthernet0/8/0 up

# 创建 VXLAN 隧道
vpp# create vxlan tunnel src 10.0.0.1 dst 10.0.0.2 vni 100
vpp# set interface ip address vxlan_tunnel0 172.16.0.1/24

# 创建 bridge domain
vpp# create bridge-domain 100
vpp# set interface l2 bridge GigabitEthernet0/8/0 100
vpp# set interface l2 bridge vxlan_tunnel0 100

# 查看表
vpp# show ip fib
vpp# show l2fib
```

## 3. FD.io 与云原生

### 3.1 FD.io 项目

FD.io 是 Linux Foundation 的项目组合：

```
FD.io (Fast Datapath)
├── VPP (Vector Packet Processing)
├── Honeycomb (NETCONF/YANG 管理)
├── HC2 (VPP + OpenStack)
├── CNX (Cloud Native VPP)
└── Vela (VPP Acceleration)
```

### 3.2 VPP Kubernetes CNI

```bash
# 1. 安装 VPP CNI
git clone https://github.com/FDio/vpp.git
cd vpp/build-root
make vpp-image

# 2. 部署 VPP CNI
kubectl apply -f deployments/vpp-cni.yaml

# 3. 配置
cat <<EOF > /etc/vpp/contiv-vpp.conf
{
    "nodes": {
        "main": {
            "vppMasterIf": "eth0"
        }
    },
    "ipam": {
        "podSubnetOne": "10.10.0.0/16"
    }
}
EOF

# 4. 启动 VPP
systemctl start vpp
```

### 3.3 Contiv-VPP 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Contiv-VPP                              │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              VPP (Data Plane)                        │   │
│  │                                                      │   │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │   │
│  │  │  Pod IF  │  │ Host IF  │  │  TAP IF  │          │   │
│  │  │ (veth)  │  │  (PHY)  │  │ (service)│          │   │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘          │   │
│  │       │              │              │                 │   │
│  │       └──────────────┼──────────────┘                 │   │
│  │                      ▼                                │   │
│  │              ┌──────────────┐                        │   │
│  │              │  L2/L3 Switch │                        │   │
│  │              │    Pipeline   │                        │   │
│  │              └──────────────┘                        │   │
│  └──────────────────────────┬───────────────────────────┘   │
│                              │                               │
│  ┌──────────────────────────▼───────────────────────────┐   │
│  │              TAP (Control Plane)                      │   │
│  │         (Kubernetes API <-> VPP)                     │   │
│  └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

## 4. Service Mesh 与 DPDK

### 4.1 Service Mesh 概述

Service mesh（如 Istio、Linkerd）为微服务提供：

- **流量管理**：负载均衡、熔断
- **安全**：mTLS 加密
- **可观测性**：指标、日志、追踪

### 4.2 Sidecar 性能问题

```
┌─────────────────────────────────────────────────────────────┐
│                    Sidecar 模式                             │
│                                                              │
│   Service A ──▶ Envoy ──▶ Network ──▶ Envoy ──▶ Service B  │
│                  ↑                                  ↑      │
│              (CPU)                                  (CPU)  │
│                                                              │
│ 问题：每个请求经过两个 proxy，延迟增加 2-5x                  │
└─────────────────────────────────────────────────────────────┘
```

### 4.3 性能对比

| 方案 | 延迟 | CPU 开销 | 复杂度 |
|------|------|----------|--------|
| **纯 Service Mesh** | ~5-10ms | 高 | 低 |
| **DPDK Sidecar** | ~1-2ms | 中 | 中 |
| **Cilium eBPF** | ~0.1-0.5ms | 低 | 中 |
| **VPP Service Proxy** | ~0.5ms | 低 | 高 |

## 5. Cilium 与云原生

### 5.1 Cilium 概述

Cilium 是 Kubernetes CNI，利用 eBPF 实现高性能网络：

```
┌─────────────────────────────────────────────────────────────┐
│                      Cilium                                 │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐ │
│  │                    eBPF Programs                       │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐          │ │
│  │  │ tc (egress)│ │  xdp     │  │ sock ops │          │ │
│  │  │           │  │          │  │          │          │ │
│  │  └──────────┘  └──────────┘  └──────────┘          │ │
│  └───────────────────────────────────────────────────────┘ │
│                            │                               │
│  ┌─────────────────────────▼───────────────────────────┐  │
│  │              Linux Kernel Networking                  │  │
│  │              (Protocol Stack - minimal)              │  │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 Cilium + VPP 融合

Cilium 可以与 VPP 结合：

```yaml
# 使用 Cilium VPP 插件
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
data:
  vpp-backend: "enabled"
  tunnel: "disabled"  # VPP handles L2
```

### 5.3 Cilium Hubble（可观测性）

```bash
# 启用 Hubble
cilium hubble enable

# 查看流量
hubble observe --type trace

# 输出示例
TIMESTAMP           SOURCE                      DESTINATION            TYPE
2024-01-15T10:00:00 10.244.0.5:8080            10.244.1.3:9090        trace-not-observed
```

## 6. Kata Containers 与 DPDK

### 6.1 Kata 容器概述

Kata Containers 提供轻量级 VM 隔离：

```
┌─────────────────────────────────────────────────────────────┐
│                    Kata Container                           │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              MicroVM (轻量级 VM)                     │   │
│  │  ┌──────────────────────────────────────────────┐   │   │
│  │  │              Guest Kernel                    │   │   │
│  │  │  ┌────────┐  ┌────────┐  ┌────────┐        │   │   │
│  │  │  │ Agent  │  │  OVS   │  │ DPDK   │        │   │   │
│  │  │  │        │  │  VPP   │  │  App   │        │   │   │
│  │  │  └────────┘  └────────┘  └────────┘        │   │   │
│  │  └──────────────────────────────────────────────┘   │   │
│  └──────────────────────────┬───────────────────────────┘   │
│                             │                                │
│  ┌─────────────────────────▼───────────────────────────┐  │
│  │              Firecracker / QEMU                      │   │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Kata + VPP

```bash
# Kata 运行时配置
cat <<EOF > /etc/kata-containers/configuration.toml
[hypervisor.vpp]
enable = true
path = "/usr/bin/vpp"

[agent.kata]
enable = true
EOF

# 启动 Kata pod
kubectl run --image=nginx nginx --runtime=kata
```

## 7. 实际部署案例

### 7.1 VPP Service Function Chaining

```bash
# 创建 SFC (Service Function Chain)
vpp# create vxlan tunnel src 10.0.0.1 dst 10.0.0.2 vni 100
vpp# set interface ip address vxlan_tunnel0 172.16.0.1/24

# 添加到 service chain
vpp# classifier table ip4 src 10.0.0.0/24
vpp# classifier rule table 0 ip4 src 10.0.0.0/24 match overlay-host save-addr
vpp# classifer policy chain

# 流量：NIC --> FW --> LB --> IPSec --> NIC
```

### 7.2 Multi-tenant VPP

```bash
# VRF (Virtual Routing and Forwarding) 隔离
vpp# vrf 100
vpp# set ip table vrf 100
vpp# ip route add 0.0.0.0/0 via 10.0.0.1

# 第二个租户
vpp# vrf 200
vpp# set ip table vrf 200
vpp# ip route add 0.0.0.0/0 via 20.0.0.1
```

## 8. 总结

云原生 DPDK 生态的关键组件：

1. **VPP**：高性能数据包处理框架
2. **FD.io**：Linux Foundation 项目组合
3. **Cilium**：eBPF 原生网络与安全
4. **Kata**：安全隔离的轻量级 VM
5. **Service Mesh**：微服务通信基础设施

**融合趋势**：
- VPP 作为高性能数据面
- eBPF/Cilium 作为云原生控制平面
- DPDK 应用作为 sidecar 或安全策略执行点

---

## 参考资源

- [FD.io VPP 官方文档](https://fd.io/)
- [VPP GitHub](https://github.com/FDio/vpp)
- [Cilium 文档](https://docs.cilium.io/)
- [Kata Containers](https://katacontainers.io/)
