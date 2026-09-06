---
title: "VPN 技术深度探索 (四十二)：Cilium 流量加密"
date: 2026-04-13
tags: [vpn, series, cilium, encryption, wireguard, ebpf, cluster-wide, cip]
description: "Cilium 流量加密深度解析——CiliumClusterWideEncryption、WireGuard 集成、CMCC/CWC 加密模式、CiliumIdentity Policy（CEP）、透明加密"
---

> [!info] VPN 技术深度探索系列 0. [[vpn-deep-dive|全栈学习路径总览]]
>
> 1. [[ch41-k8s-vpn|第四十一章：Kubernetes VPN 方案]]
> 2. **第四十二章：Cilium 流量加密**
> 3. [[ch43-subnet-router|第四十三章：Subnet Router 模式]]

---

## 1. 概述：Cilium 与 eBPF

Cilium 是一个基于 eBPF 的 Kubernetes CNI 插件，提供原生网络、网络策略和可观测性。与传统 CNI 不同，Cilium 在 Linux 内核中利用 eBPF 实现数据平面，无需依赖 iptables 或 kube-proxy：

```
Cilium 架构：

┌─────────────────────────────────────────────────────────────────┐
│                    Cilium 架构概览                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Kubernetes Cluster                      │  │
│  │                                                          │  │
│  │  ┌────────────────────────────────────────────────────┐  │  │
│  │  │                 Cilium Agent (DaemonSet)           │  │  │
│  │  │  ├─ eBPF Map Management                           │  │  │
│  │  │  ├─ Network Policy Enforcement                    │  │  │
│  │  │  ├─ Cluster Mesh                                  │  │  │
│  │  │  └─ Encryption Manager                            │  │  │
│  │  └────────────────────────────────────────────────────┘  │  │
│  │                           │                               │  │
│  │  ┌────────────────────────┼────────────────────────┐    │  │
│  │  │                        │                        │    │  │
│  │  ▼                        ▼                        ▼    │  │
│  │ Node A                  Node B                  Node C   │  │
│  │  │                        │                        │      │  │
│  │  │  eBPF Hooks           │  eBPF Hooks           │      │  │
│  │  │  ├─ tc (traffic ctrl) │  ├─ tc               │      │  │
│  │  │  └─ xdp              │  └─ xdp               │      │  │
│  │  │                        │                        │      │  │
│  │  └────────────────────────┴────────────────────────┘      │  │
│  │                           │                               │  │
│  └───────────────────────────┼───────────────────────────────┘  │
│                              ▼                                  │
│                    Linux Kernel (eBPF)                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.1 为什么选择 Cilium 加密

```
Cilium 加密优势：

┌─────────────────────────────────────────────────────────────────┐
│                    Cilium 加密特点                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  vs 传统 CNI + IPsec：                                          │
│  ├─ eBPF 数据平面，无 iptables 性能损耗                          │
│  ├─ 透明加密，无需修改应用代码                                   │
│  ├─ 加密粒度可选：节点级别、Pod 级别                             │
│  └─ 密钥自动管理                                                │
│                                                                 │
│  vs Istio mTLS：                                               │
│  ├─ 传输层加密（IPsec/WireGuard）而非应用层（TLS）              │
│  ├─ 零信任 L3/L4 网络                                          │
│  ├─ 性能更优                                                    │
│  └─ 无需 sidecar 代理                                          │
│                                                                 │
│  支持的加密方案：                                               │
│  ├─ WireGuard（推荐）                                          │
│  ├─ IPsec（向后兼容）                                          │
│  └─ 字节级加密（WireGuard）                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. CiliumClusterWideEncryption（CWC）

### 2.1 CWC 概述

CiliumClusterWideEncryption（CWC）是 Cilium 提供的集群范围加密功能：

```
CWC 架构：

┌─────────────────────────────────────────────────────────────────┐
│                    CiliumClusterWideEncryption                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Kubernetes Cluster                     │  │
│  │                                                          │  │
│  │  Node A ──────────── WireGuard ──────────── Node B       │  │
│  │     │                                        │           │  │
│  │     │ 10.0.1.x/24                         10.0.2.x/24 │  │
│  │     │                                        │           │  │
│  │     ▼                                        ▼           │  │
│  │  ┌─────────┐                          ┌─────────┐        │  │
│  │  │  Pod A  │  ═══════════════════════ │  Pod B  │        │  │
│  │  └─────────┘  端到端加密隧道           └─────────┘        │  │
│  │                                                          │  │
│  │  加密层级：                                              │  │
│  │  ├─ 节点到节点：WireGuard                                │  │
│  │  └─ Pod 到 Pod：同一隧道内                               │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  特点：                                                         │
│  ├─ 透明加密整个集群流量                                       │
│  ├─ 自动密钥交换                                                │
│  ├─ 支持 WireGuard 和 IPsec                                    │
│  └─ 可配置加密哪些流量                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 启用 CWC

```
启用 CiliumClusterWideEncryption（WireGuard）：

┌─────────────────────────────────────────────────────────────────┐
│                    CWC 部署步骤                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 安装 Cilium（含 WireGuard 支持）：                          │
│                                                                 │
│  helm install cilium cilium/cilium \                            │
│    --namespace kube-system \                                   │
│    --set encryption.enabled=true \                             │
│    --set encryption.type=wireguard \                          │
│    --set encryption.nodeEncryption=true                        │
│                                                                 │
│  2. 验证安装：                                                  │
│                                                                 │
│  # 检查 Cilium Agent 日志                                        │
│  kubectl logs -n kube-system -l k8s-app=cilium \              │
│      --tail=100 | grep -i wireguard                            │
│                                                                 │
│  # 检查节点加密状态                                              │
│  kubectl cilium encryption status -o json                      │
│                                                                 │
│  3. 检查 WireGuard 接口：                                       │
│                                                                 │
│  # 在节点上执行                                                  │
│  ip link show cilium_wg0                                       │
│  ip addr show cilium_wg0                                       │
│  wg show cilium_wg0                                            │
│                                                                 │
│  4. 验证加密流量：                                              │
│                                                                 │
│  # 从 Pod 发起流量                                              │
│  kubectl exec -it test-pod -- wget -O- http://<target-pod>:8080│
│                                                                 │
│  # 抓包验证（应该看不到明文）                                   │
│  tcpdump -i cilium_wg0 -n port 51820                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 CWC 配置选项

```
CWC 配置详解：

┌─────────────────────────────────────────────────────────────────┐
│                    CWC 配置选项                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Helm 配置参数：                                                │
│                                                                 │
│  encryption.enabled:                                           │
│    true - 启用加密                                              │
│                                                                 │
│  encryption.type:                                               │
│    wireguard - WireGuard（推荐）                               │
│    ipsec - IPsec（向后兼容）                                    │
│                                                                 │
│  encryption.nodeEncryption:                                     │
│    true - 节点间流量加密                                        │
│    false - 仅加密跨集群流量                                     │
│                                                                 │
│  encryption.keyFile:                                            │
│    密钥文件路径（可选）                                         │
│                                                                 │
│  encryption.interface:                                          │
│    加密使用的网络接口（默认自动选择）                           │
│                                                                 │
│  示例：完整配置                                                 │
│                                                                 │
│  helm install cilium cilium/cilium \                           │
│    --namespace kube-system \                                   │
│    --set encryption.enabled=true \                              │
│    --set encryption.type=wireguard \                           │
│    --set encryption.nodeEncryption=true \                       │
│    --set encryption.ipsec.keyFile=/var/lib/cilium/ipsec-keys   │
│    --set encryption.wireguard.interface=wg0                   │
│    --set debug.enabled=true                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. WireGuard 集成

### 3.1 Cilium WireGuard 工作原理

```
Cilium WireGuard 数据流：

┌─────────────────────────────────────────────────────────────────┐
│                    WireGuard 数据面                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Pod A (10.0.1.10) ───────────────────────────────────────────▶│
│                                                                 │
│  1. Pod A 发送数据包到 Pod B (10.0.2.20)                       │
│                                                                 │
│  2. eBPF 路由决策：                                             │
│     ├─ 目标在同节点：直接通过 veth 转发                         │
│     └─ 目标在远程节点：通过 cilium_wg0 隧道                     │
│                                                                 │
│  3. WireGuard 封装：                                           │
│     ├─ 原始 IP 头：SRC=10.0.1.10, DST=10.0.2.20                │
│     ├─ WireGuard 头：加密内容                                   │
│     └─ 外部 IP 头：SRC=NodeA IP, DST=NodeB IP                  │
│                                                                 │
│  4. Node B 接收：                                               │
│     ├─ 外部 IP 匹配本节点                                       │
│     ├─ WireGuard 解密                                           │
│     └─ eBPF 路由到目标 Pod                                      │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                 数据包格式对比                           │    │
│  ├─────────────────────────────────────────────────────────┤    │
│  │  明文：                                                │    │
│  │  ┌──────┬──────┬────────┬──────────┐                    │    │
│  │  │ Eth  │  IP  │  TCP  │  Data    │                    │    │
│  │  └──────┴──────┴────────┴──────────┘                    │    │
│  │                                                         │    │
│  │  WireGuard 加密：                                       │    │
│  │  ┌──────┬──────┬────────┬──────────┬─────────┐        │    │
│  │  │ Eth  │  IP  │  UDP  │  WG Header│ Encrypted│        │    │
│  │  │      │      │ :51820│          │ Data     │        │    │
│  │  └──────┴──────┴────────┴──────────┴─────────┘        │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 WireGuard 密钥管理

```
Cilium WireGuard 密钥管理：

┌─────────────────────────────────────────────────────────────────┐
│                    自动密钥管理                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  密钥生成：                                                     │
│  ├─ Cilium Agent 启动时生成私钥                                 │
│  ├─ 公钥存储在 annotations 中                                   │
│  └─ 密钥通过 Kubernetes API 共享                                │
│                                                                 │
│  密钥存储位置：                                                 │
│                                                                 │
│  Node 节点 annotation：                                         │
│  kubectl get nodes <node-name> -o jsonpath='                  │
│      {.metadata.annotations.cilium-io/wg-pub-key}'           │
│                                                                 │
│  输出示例：                                                    │
│  cilium.io/wg-pub-key:                                        │
│    aB3K4...==                                                  │
│                                                                 │
│  eBPF Map 中的密钥：                                           │
│  ├─ 节点公钥存储在 bpr_v0_peer_map                             │
│  └─ 本节点私钥存储在 bpf_netdev_cilium_wg0.map                 │
│                                                                 │
│  密钥轮换：                                                     │
│  ├─ Cilium 自动管理                                            │
│  ├─ 支持手动触发重连                                            │
│  └─ 定期重新生成密钥                                            │
│                                                                 │
│  查看密钥信息：                                                │
│  cilium-dbg encrypt status                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 性能优化

```
WireGuard 性能优化：

┌─────────────────────────────────────────────────────────────────┐
│                    性能调优                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. MTU 设置：                                                  │
│                                                                 │
│  # 建议值                                                      │
│  WireGuard MTU = 1420                                          │
│  Pod veth MTU = 1500                                           │
│                                                                 │
│  # 计算公式                                                     │
│  WireGuard MTU = Physical IF MTU - WireGuard Overhead         │
│                 = 1500 - 80 = 1420                             │
│                                                                 │
│  2. CPU 优化：                                                  │
│  ├─ WireGuard 使用单核加密                                      │
│  ├─ 建议使用多队列网卡                                          │
│  └─ 启用 RSS 将加密负载分散到多核                               │
│                                                                 │
│  3. 批处理：                                                    │
│  ├─ Cilium 支持加密批处理                                       │
│  └─ 提高高吞吐量场景性能                                        │
│                                                                 │
│  4. 内核参数：                                                  │
│                                                                 │
│  # /etc/sysctl.conf                                            │
│  net.core.rmem_max = 268435456                                 │
│  net.core.wmem_max = 268435456                                 │
│  net.ipv4.tcp_rmem = 4096 87380 134217728                     │
│  net.ipv4.tcp_wmem = 4096 87380 134217728                     │
│                                                                 │
│  5. 验证性能：                                                  │
│                                                                 │
│  # iperf3 测试                                                  │
│  kubectl exec -it test-pod -- iperf3 -c <target-pod>         │
│                                                                 │
│  # Cilium 加密统计                                              │
│  kubectl exec -it <cilium-pod> -- cilium-dbg encrypt status   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. CiliumIdentity Policy（CEP）

### 4.1 CiliumEndpoint 与 CiliumEndpointRevision

Cilium 为每个 Pod 创建一个 CiliumEndpoint（CEP）资源，记录网络元数据：

```
CiliumEndpoint 结构：

┌─────────────────────────────────────────────────────────────────┐
│                    CiliumEndpoint 资源                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  资源结构：                                                     │
│                                                                 │
│  apiVersion: cilium.io/v2                                      │
│  kind: CiliumEndpoint                                          │
│  metadata:                                                     │
│    name: sample-app-abc123                                     │
│    namespace: default                                         │
│    labels:                                                     │
│      app: sample-app                                          │
│      version: v1                                              │
│  status:                                                      │
│    id: 1234                                                    │
│    networking:                                                 │
│      nodeIP: 192.168.1.100                                    │
│      addresses:                                               │
│      - ipv4: 10.0.1.10                                       │
│        ipv6: fd00::10                                         │
│    eni:                                                        │
│      primaryMAC: 02:xx:xx:xx:xx:xx                          │
│    encryption:                                                │
│     wgPubKey: aB3K4...==                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 基于身份的加密策略

```
Cilium 加密策略（CEP Encryption）：

┌─────────────────────────────────────────────────────────────────┐
│                    CiliumEndpoint Encryption Policy               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  概念：                                                         │
│  ├─ 基于 Cilium Identity（安全标签）选择加密                     │
│  ├─ 细粒度控制哪些流量需要加密                                   │
│  └─ 替代粗粒度的「全加密」                                       │
│                                                                 │
│  加密模式：                                                     │
│  ├─ default（未设置）：使用集群默认加密                         │
│  ├─ encrypt：强制加密                                           │
│  └─ decrypt：强制不解密                                         │
│                                                                 │
│  配置示例：                                                     │
│                                                                 │
│  apiVersion: cilium.io/v2                                      │
│  kind: CiliumEndpoint                                          │
│  metadata:                                                     │
│    name: sensitive-app-xyz                                    │
│    namespace: production                                       │
│  spec:                                                        │
│    options:                                                   │
│      - name: INGRESS_REMOTE_NODE_ENCRYPTION                   │
│        value: encrypt                                         │
│      - name: EGRESS_REMOTE_NODE_ENCRYPTION                    │
│        value: encrypt                                         │
│                                                                 │
│  基于 Namespace 的默认策略：                                    │
│                                                                 │
│  apiVersion: v1                                                │
│  kind: Namespace                                               │
│  metadata:                                                     │
│    name: production                                            │
│    annotations:                                               │
│      io.cilium/encryption: wireguard                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 NetworkPolicy 加密

```
NetworkPolicy 与加密结合：

┌─────────────────────────────────────────────────────────────────┐
│                    加密的 NetworkPolicy                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  CiliumNetworkPolicy 示例：                                    │
│                                                                 │
│  apiVersion: cilium.io/v2                                      │
│  kind: CiliumNetworkPolicy                                     │
│  metadata:                                                     │
│    name: encrypted-web-policy                                  │
│  spec:                                                        │
│    endpointSelector:                                          │
│      matchLabels:                                              │
│        app: web                                                │
│        encrypted: "true"                                        │
│    ingress:                                                    │
│    - from:                                                     │
│      - endpointSelector:                                       │
│          matchLabels:                                          │
│            app: api                                            │
│      toPorts:                                                  │
│      - port: "8080"                                            │
│        protocol: TCP                                          │
│        rules:                                                  │
│          http:                                                 │
│          - method: GET                                        │
│            path: /api/*                                       │
│                                                                 │
│  效果：                                                         │
│  ├─ labeled app=web,encrypted=true 的 Pod                      │
│  ├─ 仅接受来自 app=api 的加密流量                               │
│  └─ 与传输层 WireGuard 加密协同                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. 集群间加密（Cluster Mesh）

### 5.1 Cluster Mesh 概述

Cilium Cluster Mesh 允许多个 Kubernetes 集群之间共享服务：

```
Cluster Mesh 架构：

┌─────────────────────────────────────────────────────────────────┐
│                    Cilium Cluster Mesh                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Cluster 1 (us-east)                    │  │
│  │  Node A ──────────── WireGuard ──────────── Node C       │  │
│  │  Pod:10.0.1.x                            Pod:10.1.2.x     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                            │                                    │
│                            │ Cluster Mesh 隧道                   │
│                            ▼                                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Cluster 2 (eu-west)                    │  │
│  │  Node B ──────────── WireGuard ──────────── Node D       │  │
│  │  Pod:10.1.1.x                            Pod:10.2.2.x     │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  特点：                                                         │
│  ├─ 集群间 Pod-to-Pod 直接通信                                 │
│  ├─ 跨集群 Service 访问                                        │
│  ├─ 统一网络策略                                               │
│  └─ 端到端加密                                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 配置 Cluster Mesh 加密

```
Cluster Mesh 加密配置：

┌─────────────────────────────────────────────────────────────────┐
│                    Cluster Mesh 部署步骤                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 每个集群启用 WireGuard：                                    │
│                                                                 │
│  helm install cilium cilium/cilium \                           │
│    --namespace kube-system \                                   │
│    --set encryption.enabled=true \                             │
│    --set encryption.type=wireguard                             │
│                                                                 │
│  2. 部署 clustermesh-apiserver：                               │
│                                                                 │
│  helm install clustermesh cilium/clustermesh \                 │
│    --namespace kube-system \                                   │
│    --set encryption.enabled=true \                             │
│    --set encryption.type=wireguard                             │
│                                                                 │
│  3. 配置集群互联：                                              │
│                                                                 │
│  # 获取集群 ID 和公钥                                            │
│  cilium-dbg config | grep -i cluster                          │
│  cilium-dbg encrypt status                                     │
│                                                                 │
│  # 在每个集群添加其他集群的信息                                   │
│  cilium clustermesh connect \                                  │
│    --destination-cluster cluster2 \                            │
│    --destination-kubeconfig /path/to/kubeconfig               │
│                                                                 │
│  4. 验证连接：                                                  │
│                                                                 │
│  cilium-dbg clustermesh status                                │
│                                                                 │
│  5. 跨集群服务发现：                                            │
│                                                                 │
│  # 标注 Service 为全局                                          │
│  kubectl annotate svc my-service \                            │
│    io.cilium/global-service="true"                             │
│                                                                 │
│  # 添加集群标签                                                  │
│  kubectl annotate svc my-service \                            │
│    io.cilium/shared=cluster1,cluster2                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. 监控与故障排除

### 6.1 加密状态监控

```
监控加密状态：

┌─────────────────────────────────────────────────────────────────┐
│                    Cilium 加密监控                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. CLI 检查：                                                  │
│                                                                 │
│  # 查看整体加密状态                                              │
│  kubectl cilium encrypt status                                 │
│                                                                 │
│  输出示例：                                                    │
│  Encryption: WireGuard (backend)                              │
│  ├─ Node: node-1                                              │
│  │  └─ PublicKey: aB3K4...==                                 │
│  │  └─ Status: Installed                                      │
│  └─ Node: node-2                                              │
│     └─ PublicKey: xYz12...==                                  │
│     └─ Status: Installed                                      │
│                                                                 │
│  2. Hubble 监控加密流量：                                       │
│                                                                 │
│  # 启用 Hubble                                                  │
│  helm upgrade cilium cilium/cilium \                          │
│    --set hubble.enabled=true \                                 │
│    --set hubble.ui.enabled=true                               │
│                                                                 │
│  # 查看加密流量                                                  │
│  hubble observe --protocol wireguard                          │
│                                                                 │
│  # 过滤特定 flow                                                 │
│  hubble observe --from-label app=web --to-label app=api       │
│                                                                 │
│  3. Prometheus 指标：                                          │
│                                                                 │
│  cilium_encrypt_bytes_total      # 加密字节数                   │
│  cilium_encrypt_packets_total    # 加密包数                    │
│  cilium_peer_encrypt_status      # Peer 加密状态               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 常见问题与解决

```
故障排除指南：

┌─────────────────────────────────────────────────────────────────┐
│                    常见问题                                      │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  问题 1：WireGuard 接口不存在                                   │
│                                                                 │
│  检查：                                                         │
│  ├─ Cilium Agent 是否正常运行                                  │
│  ├─ 内核是否支持 WireGuard（5.6+）                            │
│  └─ Helm 配置是否正确                                          │
│                                                                 │
│  解决：                                                         │
│  ├─ 检查 Cilium Agent 日志                                      │
│  ├─ 升级内核或加载 wireguard 模块                              │
│  └─ 重新部署 Cilium                                             │
│                                                                 │
│  问题 2：Peer 无法建立连接                                       │
│                                                                 │
│  检查：                                                         │
│  ├─ 节点间 UDP 51820 端口是否可达                              │
│  ├─ 公钥是否正确传播                                            │
│  └─ 防火墙规则                                                  │
│                                                                 │
│  解决：                                                         │
│  ├─ 检查网络连通性                                              │
│  ├─ 验证节点 annotations 中的公钥                              │
│  └─ 配置防火墙放行 UDP 51820                                   │
│                                                                 │
│  问题 3：加密流量性能下降                                       │
│                                                                 │
│  解决：                                                         │
│  ├─ 检查 CPU 使用率                                             │
│  ├─ 调整 MTU 设置                                              │
│  ├─ 使用高性能 NIC                                              │
│  └─ 考虑硬件加速                                                │
│                                                                 │
│  调试命令：                                                     │
│                                                                 │
│  # 查看详细日志                                                  │
│  cilium-dbg debuginfo --end=encrypt                           │
│                                                                 │
│  # 跟踪 WireGuard 握手                                          │
│  cilium-dbg encrypt -v trace                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 总结

```
本章要点：

┌─────────────────────────────────────────────────────────────────┐
│                    第 42 章总结                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Cilium 加密优势：                                           │
│  ├─ 基于 eBPF，无 iptables 性能损耗                             │
│  ├─ 透明加密整个集群                                            │
│  └─ 支持 WireGuard 和 IPsec                                     │
│                                                                 │
│  2. CiliumClusterWideEncryption（CWC）：                        │
│  ├─ WireGuard 节点间隧道加密                                    │
│  ├─ Helm 一键启用                                               │
│  └─ 自动密钥管理                                                │
│                                                                 │
│  3. WireGuard 集成：                                           │
│  ├─ cilium_wg0 接口                                            │
│  ├─ 自动生成和交换密钥                                          │
│  └─ 通过 annotations 暴露公钥                                   │
│                                                                 │
│  4. CiliumIdentity Policy（CEP）：                              │
│  ├─ 基于安全标签的细粒度加密                                    │
│  ├─ 可指定 ingress/egress 加密策略                             │
│  └─ 与 NetworkPolicy 协同                                      │
│                                                                 │
│  5. Cluster Mesh：                                              │
│  ├─ 跨集群 Pod 直接通信                                         │
│  ├─ 统一网络策略                                                │
│  └─ 端到端加密                                                  │
│                                                                 │
│  6. 监控排错：                                                  │
│  ├─ cilium encrypt status                                      │
│  ├─ Hubble 观察加密流量                                          │
│  └─ Prometheus 指标监控                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

> [!info] 下一章预告
> [[ch43-subnet-router|第四十三章：Subnet Router 模式]]——深入解析 WireGuard 的路由模式，包括 Subnet Router、boringtun 用户空间实现、路由表管理。
