---
title: "Cilium 深度探索 (44)：BGP 网络集成"
date: 2026-04-14
tags:
  - cilium
  - bgp
  - networking
  - cilium-bgp
  - cluster-mesh
  - external-networking
  - bird
  - frr
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ...
> 41. [[2026-04-14-cilium-deep-dive-ch41-debug|第四十一章：故障诊断]]
> 42. [[2026-04-14-cilium-deep-dive-ch42-performance|第四十二章：性能调优]]
> 43. [[2026-04-14-cilium-deep-dive-ch43-ecosystem|第四十三章：Cilium 生态概述]]
> 44. **第四十四章：BGP 网络集成** ←
> 45. [[2026-04-14-cilium-deep-dive-ch45-security|第四十五章：安全生态集成]]
> 46. [[2026-04-14-cilium-deep-dive-ch46-operator|第四十六章：扩展与 Operator]]

---

## 1. BGP 概述与 Cilium BGP

BGP (Border Gateway Protocol) 是互联网的核心路由协议，Cilium 通过 CiliumBGPControlPlane (BGPCP) 提供 BGP 能力，使 Kubernetes 集群可以向外部网络宣告 Pod CIDR 和 Service IP。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Cilium BGP 架构                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Control Plane                                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                                                             │   │
│   │   ┌─────────────────────┐    ┌─────────────────────┐        │   │
│   │   │  Cilium Operator    │    │   eBGP Peer         │        │   │
│   │   │  (BGP Control Plane)│    │   (External Router) │        │   │
│   │   └──────────┬──────────┘    └─────────────────────┘        │   │
│   │              │                                              │   │
│   │              │  BGP Session (TCP 179)                        │   │
│   │              ├───────────────────────────────────────────────┤   │
│   │              │                                              │   │
│   │              ↓                                              │   │
│   │   ┌─────────────────────────────────────────────────────┐  │   │
│   │   │              GoBGP / FRR / Bird                      │  │   │
│   │   │         (BGP Implementation)                         │  │   │
│   │   └─────────────────────────────────────────────────────┘  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   Data Plane                                                             │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                                                             │   │
│   │   ┌─────────────┐         ┌─────────────┐                   │   │
│   │   │  Pod CIDR   │         │ Service IP  │                   │   │
│   │   │  10.0.0.0/8 │         │ 172.20.0.0/16│                  │   │
│   │   └─────────────┘         └─────────────┘                   │   │
│   │         │                       │                           │   │
│   │         └───────────┬───────────┘                           │   │
│   │                     │                                        │   │
│   │                     ↓                                        │   │
│   │            ┌─────────────────────┐                           │   │
│   │            │   eBPF (Routing)    │                           │   │
│   │            │   L3 Forwarding     │                           │   │
│   │            └─────────────────────┘                           │   │
│   │                     │                                        │   │
│   └─────────────────────┼────────────────────────────────────────┘   │
│                         │                                             │
│                         ↓                                             │
│              ┌─────────────────────┐                                  │
│              │  Physical Network   │                                  │
│              │  (Top-of-Rack Switch)│                                  │
│              └─────────────────────┘                                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Cilium BGP 安装与配置

### 2.1 启用 BGP

```bash
# 使用 Helm 启用 BGP
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set bgpControlPlane.enabled=true \
  --set bgpControlPlane.announce.loadbalancerIP=true \
  --set bgpControlPlane.announce.podCIDR=true

# 验证 BGP 状态
kubectl get bgpciliumconfig
```

### 2.2 BGP 配置 CRD

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPControlPlane
metadata:
  name: bgp-config
spec:
  bgpInstances:
    - name: "instance1"
      ASN: 65001
      peers:
        - name: "external-router"
          address: 192.168.1.1
          port: 179
          passiveMode: false
          # 远程 AS 号
          remoteASN: 65000
      exportPodCIDR: true
      exportService: true
      vrfSpec:
        # 可选：VRF 名称
        name: "bgp-vrf"
        # VRF 路由表
        routeTableID: 1001
```

### 2.3 宣告 LoadBalancer IP

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPControlPlane
metadata:
  name: lb-bgp-config
spec:
  bgpInstances:
    - name: "lb-instance"
      ASN: 65001
      peers:
        - name: "router1"
          address: 192.168.1.1
          remoteASN: 65000

# Service 注解启用 BGP 宣告
apiVersion: v1
kind: Service
metadata:
  name: nginx
  annotations:
    # 宣告此 Service 到 BGP
    io.cilium/bgp-advertisement: "lbpool"
    # 指定宣告的 IP 池
    io.cilium/bgp-pool-name: "lbpool"
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 80
  selector:
    app: nginx
```

```yaml
# 定义 BGP IP Pool
apiVersion: cilium.io/v2
kind: CiliumBGPPeer
metadata:
  name: router1
spec:
  peerAddress: 192.168.1.1/32
  peerASN: 65000

---
apiVersion: cilium.io/v2
kind: CiliumBGPNodeConfig
metadata:
  name: node-1
spec:
  nodeRef:
    name: node-1
  bgpInstances:
    - instance: "default"
      localASN: 65001
      peers:
        - peer: router1

---
apiVersion: cilium.io/v2
kind: CiliumBGPadvertisement
metadata:
  name: lbpool
spec:
  pools:
    - name: lbpool
      # 分配给 LoadBalancer 的 IP 范围
      cidr: "172.20.0.0/16"
      exclusion:  # 排除的子网
        - "172.20.1.0/24"
```

---

## 3. BGP 路由宣告

### 3.1 Pod CIDR 宣告

```bash
# Pod CIDR 路由示例
# 在外部路由器上看到的路由

# Router# show ip route
# ...
# B    10.0.0.0/8 [20/0] via 192.168.1.10, eth0   # Pod CIDR
# B    172.20.1.0/24 [20/0] via 192.168.1.10, eth0 # Service IP
# ...

# 检查 Cilium 宣告的路由
cilium bgp routes ls
```

### 3.2 路由策略

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPControlPlane
metadata:
  name: bgp-policy-config
spec:
  bgpInstances:
    - name: "instance1"
      ASN: 65001
      peers:
        - name: "router1"
          address: 192.168.1.1
          remoteASN: 65000
      # 宣告配置
      exportPodCIDR: true
      exportService: true
      # 路由映射 (Route Map)
      localPreference: 100
      communities:
        standard: "65001:100"
        extended: "65001:1000"
```

---

## 4. 多集群 BGP

### 4.1 Cluster Mesh 与 BGP

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    跨集群 BGP 组网                                      │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Cluster A (ASN 65001)           Cluster B (ASN 65002)                  │
│   ┌─────────────────┐            ┌─────────────────┐                     │
│   │  Node: 10.0.1.1 │            │  Node: 10.0.2.1 │                     │
│   │  Pod CIDR:      │    BGP     │  Pod CIDR:      │                     │
│   │  10.1.0.0/16    │◄──────────►│  10.2.0.0/16    │                     │
│   │                 │            │                 │                     │
│   │  Service:       │            │  Service:       │                     │
│   │  172.20.1.0/24  │            │  172.20.2.0/24  │                     │
│   └─────────────────┘            └─────────────────┘                     │
│            │                              │                              │
│            │  Cluster Mesh (VXLAN)        │                              │
│            └──────────────────────────────┘                              │
│                                                                         │
│   外部路由器学习到两个集群的路由，实现全局可达                              │
│                                                                         │
│   路由表:                                                                │
│   10.1.0.0/16 → Cluster A                                               │
│   10.2.0.0/16 → Cluster B                                               │
│   172.20.0.0/16 → 两集群 (ECMP)                                         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 跨集群 Service 宣告

```yaml
# Cluster A 上的 Global Service
apiVersion: cilium.io/v2
kind: CiliumGlobalService
metadata:
  name: global-nginx
spec:
  clusters:
    - name: cluster-a
      displayName: "Production Cluster A"
    - name: cluster-b
      displayName: "Production Cluster B"
---
# 启用 BGP 跨集群宣告
apiVersion: cilium.io/v2
kind: CiliumBGPControlPlane
metadata:
  name: cluster-mesh-bgp
spec:
  bgpInstances:
    - name: "global-lb"
      ASN: 65001
      exportService: true
      # 跨集群 Service 也被宣告
      vrfSpec:
        name: "global"
```

---

## 5. BGP 与cilium-health

```bash
# cilium-health 提供 BGP 状态检测
kubectl get ciliumhealth

# BGP 连通性检查
cilium health status --verbose

# 示例输出
# Operator:        Reachable
# Node: node-1:    Reachable
#   ├─ BGP:        Reachable ( Established )
#   └─ API:        Reachable

# BGP 会话状态
cilium bgp peers ls

# Peer                ASN     State       Tables Version
# 192.168.1.1         65000   Established 2      12345
```

---

## 6. 高可用 BGP 配置

### 6.1 多 BGP Peer

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPControlPlane
metadata:
  name: ha-bgp-config
spec:
  bgpInstances:
    - name: "instance1"
      ASN: 65001
      # Router ID (通常使用节点 IP)
      routerID: 192.168.1.10
      # 连接重试计时器
      connectRetryTimeSeconds: 120
      # 保持计时器
      holdTimeSeconds: 9
      # 邻居 keepalive 间隔
      keepAliveTimeSeconds: 3
      peers:
        - name: "router1"
          address: 192.168.1.1
          remoteASN: 65000
          # 优先级 (主)
          gracefulRestart:
            enabled: true
            restartTimeSeconds: 120
        - name: "router2"
          address: 192.168.1.2
          remoteASN: 65000
          # 备份 peer
          gracefulRestart:
            enabled: true
            restartTimeSeconds: 120
```

### 6.2 ECMP 负载均衡

```bash
# 外部路由器启用 ECMP
# 两条等价路径自动负载均衡

# 查看 ECMP 路由
ip route

# 10.1.0.0/16  proto zebra
#         nexthop via 192.168.1.10  weight 1
#         nexthop via 192.168.2.10  weight 1
```

---

## 7. BGP 日志与故障排查

### 7.1 BGP 日志

```bash
# 查看 BGP 状态
kubectl get bgpciliumconfig -o yaml

# 查看 Operator 日志
kubectl logs -n kube-system -l name=cilium-operator --tail=100 | grep -i bgp

# 查看 Agent BGP 日志
kubectl logs -n kube-system ds/cilium | grep -i bgp
```

### 7.2 常见问题

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    BGP 常见问题与解决方案                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   问题 1: BGP Session 无法建立                                           │
│   ─────────────────────────────                                          │
│   原因:                                                                   │
│   • TCP 179 端口被防火墙阻止                                              │
│   • ASN 配置不匹配                                                        │
│   • MTU 问题 (VXLAN over BGP 需要更大 MTU)                               │
│                                                                         │
│   排查:                                                                   │
│   telnet <peer-ip> 179                                                  │
│   tcpdump -i any tcp port 179                                           │
│   cilium bgp peers ls                                                   │
│                                                                         │
│   ────────────────────────────────────────                              │
│   问题 2: 路由未宣告                                                       │
│   ─────────────────────────                                                      │
│   原因:                                                                   │
│   • BGPCP 配置错误                                                        │
│   • Pod/Service Selector 未匹配                                          │
│   • 路由策略过滤                                                          │
│                                                                         │
│   排查:                                                                   │
│   cilium bgp routes ls                                                  │
│   kubectl get bgpadvertisement                                          │
│                                                                         │
│   ────────────────────────────────────────                              │
│   问题 3: 跨集群通信失败                                                   │
│   ─────────────────────────────                                                      │
│   原因:                                                                   │
│   • Cluster Mesh 未正确配置                                               │
│   • VXLAN 封装问题                                                        │
│   • 路由策略问题                                                          │
│                                                                         │
│   排查:                                                                   │
│   cilium clustermesh status                                             │
│   ip link show cilium_vxlan                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.3 调试命令

```bash
# 查看 BGP 详细信息
cilium bgp peers ls -o json

# 查看宣告的路由
cilium bgp routes ls

# 查看 BGP 邻居状态
cilium bgp neighbor ls

# 测试 BGP 连通性
kubectl exec -n kube-system ds/cilium -- cilium bgp peers ls

# 查看路由表
kubectl exec -n kube-system ds/cilium -- ip route

# 查看 BGP 配置
kubectl get CiliumBGPControlPlane -o yaml
```

---

## 8. 替代方案：外部 BGP Speaker

如果 Cilium 内置 BGP 不满足需求，可以使用外部 BGP Speaker：

### 8.1 Bird BGP Speaker

```bash
# 在每个节点部署 Bird
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: bird-bgp
  namespace: kube-system
spec:
  template:
    spec:
      hostNetwork: true
      containers:
        - name: bird
          image: quay.io/cilium/bird:latest
          securityContext:
            privileged: true
          volumeMounts:
            - name: cni-path
              mountPath: /host/etc/cni/net.d
            - name: bird-config
              mountPath: /etc/bird
          env:
            - name: Bird_CONFIG
              value: /etc/bird/bird.conf
      volumes:
        - name: bird-config
          configMap:
            name: bird-config
```

### 8.2 FRR (Free Range Routing)

```bash
# FRR BGP 配置
router bgp 65001
  neighbor 192.168.1.1 remote-as 65000
  !
  address-family ipv4 unicast
    network 10.0.0.0/8
    redistribute kernel
  exit-address-family
```

---

## 9. BGP 性能考虑

| 参数 | 默认值 | 调优建议 |
|:---|:---|:---|
| HoldTime | 9s | 保持较低减少资源占用 |
| KeepAlive | 3s | 建议为 HoldTime 的 1/3 |
| ConnectRetry | 120s | 网络不稳定时增加 |
| TableMap | - | 可用于过滤路由 |
| Prefix Limit | - | 防止路由泛洪 |

---

## 10. 总结

Cilium BGP 集成提供了一种优雅的方式将 Kubernetes 网络与传统网络基础设施统一：

1. **Pod CIDR 宣告**：外部路由器可以直接路由 Pod 流量，无需 NAT
2. **Service LoadBalancer 宣告**：Service IP 可直接从外部访问
3. **多集群组网**：通过 BGP 实现跨集群网络
4. **高可用**：支持多 BGP Peer 和 ECMP

下一章我们将探讨 Cilium 与安全生态的集成，包括 PKI、TLS/mTLS 等。
