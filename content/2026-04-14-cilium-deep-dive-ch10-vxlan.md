---
title: "Cilium 深度探索 (10)：VXLAN Overlay 网络"
date: 2026-04-14
tags:
  - cilium
  - vxlan
  - geneve
  - overlay
  - tunnel
  - vtep
  - ebpf
  - kubernetes
  - networking
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. [[2026-04-14-cilium-deep-dive-ch6-clusterip|第六章：ClusterIP]]
> 7. [[2026-04-14-cilium-deep-dive-ch7-nodeport|第七章：NodePort]]
> 8. [[2026-04-14-cilium-deep-dive-ch8-loadbalancer|第八章：LoadBalancer]]
> 9. [[2026-04-14-cilium-deep-dive-ch9-externalip|第九章：ExternalIP]]
> 10. **第十章：VXLAN** ←

---

## 1. VXLAN 概述

VXLAN（Virtual Extensible LAN）是一种**Overlay 网络协议**，通过 UDP 封装在三层网络上创建二层虚拟网络。在 Kubernetes 集群中，VXLAN 用于**跨节点 Pod 通信**，即使节点不在同一物理网络：

```
┌─────────────────────────────────────────────────────────────┐
│                   VXLAN Overlay 网络                         │
│                                                             │
│  Node A (10.0.1.10)                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Pod A (10.0.2.1)                                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ VXLAN (UDP 4789)               │
│                           │ encapsulation                   │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            Underlay Network (物理网络)                │   │
│  │                                                      │   │
│  │  10.0.1.10 ←──── VXLAN Tunnel ────→ 10.0.2.10      │   │
│  │            (UDP 4789, outer: IP+UDP+VXLAN)          │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ VXLAN decapsulation            │
│                           ▼                                 │
│  Node B (10.0.2.10)                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Pod B (10.0.3.1)  ←── 跨节点通信成功 ────           │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 为什么需要 VXLAN？

| 问题 | 解决方案 | VXLAN 优势 |
|:---|:---|:---|
| Pod IP 跨节点不可路由 | 封装在 UDP 包内 | 穿透三层网络 |
| VPC/网络限制 | Overlay 网络 | 独立 IP 平面 |
| Pod IP 漂移 | VTEP 固定 | 流量总能找到节点 |
| MAC 地址泛洪 | VNI 隔离 | 支持更多网络 |

### 1.2 VXLAN vs Geneve

Cilium 支持两种隧道协议：

| 特性 | VXLAN | Geneve |
|:---|:---|:---|
| **标准** | RFC 7348 | RFC 8926 |
| **封装** | 固定头 | 可扩展 TLV |
| **元数据** | 有限 (VNI) | 灵活 (类 Type-Length-Value) |
| **硬件支持** | 广泛 | 逐渐支持 |
| **Cilium 支持** | ✅ 默认 | ✅ 可选 |
| **性能** | 略优 | 略高灵活性 |

Cilium 默认使用 **VXLAN**，但在需要传输额外元数据时使用 **Geneve**（如用于实现 Transparent Encryption）。

---

## 2. VXLAN 封装原理

### 2.1 VXLAN 数据包格式

```
┌─────────────────────────────────────────────────────────────────┐
│                        VXLAN 封装格式                            │
│                                                                 │
│  Outer Ethernet Header (Layer 2)                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Dst MAC │ Src MAC │ EtherType = 0x0800 (IPv4)        │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Outer IP Header                                               │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Src = Node A IP (10.0.1.10)                           │   │
│  │  Dst = Node B IP (10.0.2.10)                           │   │
│  │  Protocol = UDP (17)                                    │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Outer UDP Header                                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Src Port = 随机 (ECMP 负载均衡)                        │   │
│  │  Dst Port = 4789 (VXLAN) / 6081 (Geneve)               │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  VXLAN Header                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  VXLAN Flags = 0x08 (I bit = 1, 表示有 VNI)            │   │
│  │  Reserved = 24 bits                                     │   │
│  │  VNI = 24 bits (Virtual Network Identifier)            │   │
│  │  Reserved = 8 bits                                     │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Inner Ethernet Header (Original Packet)                        │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Dst MAC = Pod B MAC                                    │   │
│  │  Src MAC = Pod A MAC                                    │   │
│  │  EtherType = 0x0800 (IPv4)                             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Inner IP Header (Original Pod Packet)                         │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Src = Pod A IP (10.0.2.1)                             │   │
│  │  Dst = Pod B IP (10.0.3.1)                             │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  Inner TCP/UDP Header                                          │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Src Port = 随机                                        │   │
│  │  Dst Port = 8080                                       │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 VNI (VXLAN Network Identifier)

VNI 是 24 位标识符，支持 16M 虚拟网络：

```c
// VNI 结构
struct vxlanhdr {
    __u8  flags;      // 0x08 (I bit set)
    __u8  reserved[3];
    __u8  vni[3];     // VNI (Network Byte Order)
    __u8  reserved;
};
```

**Cilium 中的 VNI 使用**：

- 每个 Kubernetes Cluster 有一个基础 VNI（默认 1）
- Cluster Mesh 时每个远程集群分配不同 VNI
- Transparent Encryption 使用单独 VNI

---

## 3. Cilium VXLAN 实现

### 3.1 组件架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Cilium VXLAN 架构                         │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Tunnel Endpoint Map                     │   │
│  │                                                      │   │
│  │  cilium_tunnel_map                                  │   │
│  │  Key: {NodeIP, VNI}                                 │   │
│  │  Value: {RemoteIP, MAC, IfIndex}                    │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              eBPF Encapsulation                       │   │
│  │                                                      │   │
│  │  TC Ingress/Egress Hook                             │   │
│  │  • 查找 tunnel_map                                   │   │
│  │  • 添加 VXLAN/Geneve 头                             │   │
│  │  • 发送到 remote node                               │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              cilium_vxlan device                     │   │
│  │                                                      │   │
│  │  系统网卡（vxlan_sys_67xx）                         │   │
│  │  • 接收封装/解封装                                   │   │
│  │  • 与 eBPF 协同工作                                  │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 eBPF Tunnel Map

```c
// bpf/lib/tunnel.h

struct tunnel_key {
    __u32 addr;        // 远程节点 IP
    __u32 vni;         // VNI
};

struct tunnel_value {
    __u32 addr;        // 远程节点 IP
    __u8  mac[6];      // 远程节点 MAC
    __u8  ifindex;     // 输出接口索引
    __u32 error;       // 错误码
};

// eBPF 程序中查找隧道端点
static __always_inline struct tunnel_value *
tunnel_lookup(__u32 node_ip, __u32 vni) {
    struct tunnel_key key = {
        .addr = node_ip,
        .vni = vni,
    };

    return bpf_map_lookup_elem(&cilium_tunnel_map, &key);
}
```

### 3.3 安装配置

```bash
# 使用 VXLAN 隧道模式安装 Cilium
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set tunnel=vxlan \
    --set tunnel.address=10.0.0.0/8  # 集群内部 CIDR

# 或者使用 Geneve
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set tunnel=geneve

# 查看当前隧道配置
kubectl -n kube-system exec ds/cilium -- \
    cilium config | grep -E "tunnel|vxlan"
```

---

## 4. Tunnel Endpoint (VTEP)

### 4.1 VTEP 概述

VTEP（VXLAN Tunnel EndPoint）是进行 VXLAN 封装/解封装的节点：

```
┌─────────────────────────────────────────────────────────────┐
│                    VTEP 工作流程                              │
│                                                             │
│  Node A (VTEP)                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ Pod A 发送数据包                                      │   │
│  │   Src: 10.0.2.1, Dst: 10.0.3.1                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │         TC Egress Hook + eBPF                        │   │
│  │                                                      │   │
│  │  1. 路由判断：目标在远程节点                         │   │
│  │  2. 查找 tunnel_map：Node B 的 IP+MAC               │   │
│  │  3. 添加 VXLAN 头                                    │   │
│  │  4. 从 cilium_vxlan 设备发送                        │   │
│  └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│  ┌─────────────────────────────────────────────────────┐   │
│  │            cilium_vxlan 系统设备                    │   │
│  │                                                      │   │
│  │  eth0 ←── VXLAN 封装后发送                          │   │
│  │  (vxlan_sys_67xx)                                   │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 VTEP 设备

Cilium 在每个节点创建一个 VXLAN 设备：

```bash
# 查看 VXLAN 设备
ip link show | grep -E "vxlan|cilium"

# 示例输出：
# 7: cilium_vxlan: <BROADCAST,MULTICAST,UP> mtu 1500
#     link/ether aa:bb:cc:dd:ee:ff
#     vxlan id 1 local 10.0.1.10 port 8472 nolearning

# 查看 VXLAN 设备详情
ip -d link show cilium_vxlan

# VXLAN 参数：
#   id 1              - VNI = 1
#   local 10.0.1.10   - 本地节点 IP
#   port 8472         - 源端口（Linux VXLAN 固定 8472）
#   nolearning        - 不自动学习 MAC（由 eBPF 控制）
```

### 4.3 节点发现与注册

Cilium 通过 **CiliumNode** 自定义资源发现集群中的其他节点：

```yaml
# CiliumNode 资源示例
apiVersion: cilium.io/v2
kind: CiliumNode
metadata:
  name: node-2
spec:
  ipam:
    podCIDRs:
    - 10.0.2.0/24      # Node 2 的 Pod CIDR
  encryption:
    enabled: false
  tunnel:
  - address: 10.0.2.10   # Node 2 的物理 IP
    protocol: vxlan
```

**节点注册流程**：

```
1. Cilium Agent 启动
       │
       ▼
2. 创建 CiliumNode 资源（包含 PodCIDR、IP）
       │
       ▼
3. 其他节点的 Cilium Agent 监听到事件
       │
       ▼
4. 更新 tunnel_map（Remote IP → Remote MAC）
       │
       ▼
5. eBPF 程序可以使用隧道发送数据到该节点
```

---

## 5. 跨节点 Pod 通信流程

### 5.1 同节点通信

```
Pod A (Node A) → Pod B (Node A)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│                     Node A 本地转发                          │
│                                                             │
│  1. Pod A eth0 → veth pair → cilium_host                  │
│  2. TC Ingress Hook                                        │
│  3. 查找 cilium_endpoints，目标是本地 Pod                   │
│  4. 发送到 Pod B veth pair                                 │
│                                                             │
│  不经过 VXLAN！                                            │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 跨节点通信（发送流程）

```
Pod A (Node A, 10.0.2.1) → Pod B (Node B, 10.0.3.1)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│                      Node A 处理                             │
│                                                             │
│  1. Pod A eth0 → veth pair → cilium_host                  │
│  2. TC Ingress Hook                                         │
│  3. 查找 cilium_endpoints，目标是远程 Pod (10.0.3.1)       │
│  4. 查找 tunnel_map，找到 Node B (10.0.2.10)               │
│  5. 添加 VXLAN 头 (VNI=1, inner dst=10.0.3.1)             │
│  6. 从 cilium_vxlan 设备发送                               │
│  7. 物理网络传输到 Node B eth0                            │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 跨节点通信（接收流程）

```
物理网络 → Node B eth0 → cilium_vxlan
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│                      Node B 处理                             │
│                                                             │
│  1. eth0 接收 VXLAN 封包                                    │
│  2. 内核VXLAN 模块解封装（或 eBPF 处理）                    │
│  3. 提取 inner packet (dst=10.0.3.1)                        │
│  4. 查找 cilium_endpoints，找到 Pod B                       │
│  5. 通过 veth pair 发送到 Pod B                            │
│  6. Pod B 接收原始数据包                                    │
└─────────────────────────────────────────────────────────────┘
```

### 5.4 完整时序图

```
Pod A              Node A eBPF          Node B eBPF          Pod B
   │                    │                     │                 │
   │ TCP SYN            │                     │                 │
   │ ──────────────────►│                     │                 │
   │                    │                     │                 │
   │                    │ TC Ingress          │                 │
   │                    │ 查找 endpoint       │                 │
   │                    │ 目标在远程          │                 │
   │                    │                     │                 │
   │                    │ VXLAN 封装          │                 │
   │                    │ VNI=1, Src=10.0.2.1│                 │
   │                    │ Dst=10.0.3.1        │                 │
   │                    │                     │                 │
   │                    │ 发送到 cilium_vxlan │                 │
   │                    │─────────────────────►│                 │
   │                    │                     │                 │
   │                    │               eth0接收              │
   │                    │               解封装VXLAN           │
   │                    │               TC Ingress           │
   │                    │               查找endpoint          │
   │                    │               目标是本地Pod          │
   │                    │                     │                 │
   │                    │                     │ TCP SYN        │
   │                    │                     │ ──────────────►│
   │                    │                     │                 │
   │                    │                     │                 │
   │                    │                     │ TCP SYN-ACK    │
   │                    │                     │ ◄──────────────│
   │                    │                     │                 │
   │                    │ VXLAN 封装          │                 │
   │                    │◄─────────────────────│                 │
   │                    │                     │                 │
   │ TCP SYN-ACK        │                     │                 │
   │ ◄─────────────────││                     │                 │
```

---

## 6. 直接路由 vs VXLAN

### 6.1 路由模式

当节点在同一二层网络时，可以使用**直接路由**（不经过 VXLAN）：

```bash
# 启用直接路由模式
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set tunnel=disabled   # 禁用 VXLAN
    # 或
    --set tunnel=vxlan \
    --set autoDirectNodeRoutes=true  # 自动发现直连路由
```

**直接路由架构**：

```
Pod A (Node A) → Pod B (Node B)
       │
       ▼
┌─────────────────────────────────────────────────────────────┐
│                     直接路由模式                              │
│                                                             │
│  Pod A → veth → cilium_host → 物理网卡 eth0                │
│                              ↓                              │
│                       物理交换机                             │
│                              ↓                              │
│                       eth0 → veth → Pod B                  │
│                                                             │
│  不经过 VXLAN 封装！                                        │
│  要求：Node A 和 Node B 在同一二层网络                      │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 混合模式

Cilium 支持**混合模式**：本地流量直接路由，跨网络流量使用 VXLAN：

```bash
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set tunnel=vxlan \
    --set autoDirectNodeRoutes=true \
    --set tunnelRouteMode=per-node  # 每节点路由策略
```

### 6.3 模式对比

| 模式 | 延迟 | 吞吐量 | 要求 | 适用场景 |
|:---|:---|:---|:---|:---|
| **VXLAN** | 略高 | 略低 | 无 | 跨网络、跨云、跨机房 |
| **直接路由** | 最低 | 最高 | 二层可达 | 同机房、同 VPC |
| **混合** | 动态 | 动态 | 灵活 | 大规模集群 |

---

## 7. 性能优化

### 7.1 VXLAN 硬件卸载

支持 VXLAN 卸载到网卡（降低 CPU 开销）：

```bash
# 检查网卡是否支持 VXLAN 卸载
ethtool -k eth0 | grep vxlan

# 示例输出：
# tx-vlan-offload: on
# vxlan-par offload: on  ← 支持

# 启用 VXLAN 卸载
ethtool -K eth0 tx-vlan-offload on
```

### 7.2 GENEVE 替代 VXLAN

Geneve 支持更多元数据，适合需要携带额外信息的场景：

```bash
# 使用 Geneve
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set tunnel=geneve
```

### 7.3 MTU 配置

VXLAN 封装会增加额外头部，需要调整 MTU：

```
物理网卡 MTU: 1500
减去 VXLAN 头部: 50 (ETH+IP+UDP+VXLAN)
Pod 网络 MTU: 1450
```

```bash
# 配置 Cilium MTU
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set mtu=1450
```

---

## 8. 验证与排错

### 8.1 查看 Tunnel 状态

```bash
# 查看所有节点的隧道配置
kubectl -n kube-system exec ds/cilium -- \
    cilium node list

# 输出示例：
# NODE         NAME                                              IPs
# node-1       node-1                                        10.0.1.10
# node-2       node-2                                        10.0.2.10
# node-3       node-3                                        10.0.3.10

# 查看 tunnel_map 内容
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf tunnel list

# 输出示例：
# TUNNEL                                        ID   BE PORT
# 10.0.2.10:8472                                10   1
# 10.0.3.10:8472                                11   1
```

### 8.2 测试跨节点连通性

```bash
# 1. 获取 Pod IP
POD_A=$(kubectl get pod -n default -l app=a -o jsonpath='{.items[0].status.podIP}')
POD_B=$(kubectl get pod -n default -l app=b -o jsonpath='{.items[0].status.podIP}')

# 2. 从 Pod A 测试到 Pod B
kubectl exec -it app-a -- \
    ping -c 3 $POD_B

# 3. 查看路由
kubectl exec -it app-a -- \
    ip route get $POD_B

# 4. tcpdump 抓包分析
# 在 Node B 上抓取 VXLAN 流量
ssh node-b "tcpdump -i eth0 -n 'udp port 8472' -c 10"
```

### 8.3 查看 VXLAN 设备统计

```bash
# 查看 VXLAN 设备统计
ip -s link show cilium_vxlan

# 查看 encapsulation 统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf tunnel stats

# 查看 eBPF 封装计数器
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf metrics list | grep -E "encaps|txlb"
```

### 8.4 常见问题与解决

| 问题 | 原因 | 解决方法 |
|:---|:---|:---|
| 跨节点不通 | 防火墙阻止 UDP 8472 | 开放 8472/6081 端口 |
| VXLAN 不工作 | 节点 IP 配置错误 | 检查 tunnel_map 配置 |
| MTU 问题 | 包被分片 | 降低 Pod MTU 到 1450 |
| VNI 不匹配 | 多个集群 VNI 冲突 | 修改 cluster-id |
| tunnel_map 为空 | 节点未注册 | 检查 CiliumNode 资源 |
| 封装失败 | 物理网络 MTU 小 | 使用直接路由或降低 MTU |

---

## 9. 章节总结

|| 主题 | 关键点 |
|:---|:---|:---|
| **VXLAN 封装** | UDP 4789 封装 | 穿透三层网络，创建 Overlay |
| **VNI** | 24 位网络标识 | 支持 16M 虚拟网络 |
| **VTEP** | 封装/解封装点 | CiliumNode 注册 |
| **eBPF Tunnel Map** | 节点发现 | Remote IP → MAC 映射 |
| **直接路由** | 无封装 | 低延迟，需要二层可达 |

**VXLAN vs 直接路由**：

- **VXLAN**：通用性强，跨网络/云/机房，但有封装开销
- **直接路由**：性能最优，但要求二层网络
- **混合模式**：Cilium 自动选择最优路径

**Part II 网络功能总结**：

| 章节 | 主题 | 数据平面 |
|:---|:---|:---|
| Ch6 | ClusterIP | eBPF Map O(1) 查找 |
| Ch7 | NodePort | XDP 网卡驱动层处理 |
| Ch8 | LoadBalancer | XDP + 云厂商 LB 集成 |
| Ch9 | ExternalIP | sk_lookup Hook |
| Ch10 | VXLAN | eBPF Tunnel 封装 |

**下一章预告**：Part III 网络策略——CiliumNetworkPolicy、NetworkPolicy、L7 策略的深度解析。

---

## 参考资料

- [Cilium VXLAN Documentation](https://docs.cilium.io/en/stable/concepts/networking/vxlan/)
- [VXLAN RFC 7348](https://tools.ietf.org/html/rfc7348)
- [Geneve RFC 8926](https://tools.ietf.org/html/rfc8926)
- [Cilium Tunnel Documentation](https://docs.cilium.io/en/stable/concepts/networking/tunnel/)
- [Linux VXLAN HOWTO](https://www.kernel.org/doc/html/latest/networking/vxlan.html)
