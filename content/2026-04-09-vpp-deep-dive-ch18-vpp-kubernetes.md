---
title: "VPP 深入探讨 ch18：VPP + Kubernetes"
date: 2026-04-10 03:00:00
tags: [vpp, kubernetes, k8s, service, cni, gateway, lb, ingress, envoy]
description: "深入解析 VPP 与 Kubernetes 集成：Service、LBM、Gateway、Ingress、Envoy 代理与 CNI 多网络"
---

# VPP 深入探讨 ch18：VPP + Kubernetes

> [!abstract] 核心要点
> VPP 在 Kubernetes 中可作为高性能数据平面。本章深入解析 VPP CNI、Service、LBM、Gateway、Ingress 与 Envoy 集成。

## 1. Kubernetes 网络概述

### 1.1 Kubernetes 网络模型

```
Kubernetes 网络模型：

1. Pod 内容器：共享网络命名空间
2. Pod 之间：无需 NAT 直接通信
3. Node 之间：Pod 可通过 CNI 直接通信
4. Service：提供稳定的服务发现

┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes 网络                         │
│                                                              │
│  Pod A           Pod B           Pod C                      │
│  ┌─────┐         ┌─────┐         ┌─────┐                    │
│  │ C1  │◀───────▶│ C2  │◀───────▶│ C3  │                    │
│  │ C2  │         │     │         │     │                    │
│  └─────┘         └─────┘         └─────┘                    │
│      │               │               │                       │
│      └───────────────┼───────────────┘                       │
│                      ↓                                        │
│               ┌──────────────┐                               │
│               │   Service    │                               │
│               │  (ClusterIP) │                               │
│               └──────────────┘                               │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 VPP 在 K8s 中的角色

```
VPP 可以替代 kube-proxy 作为高性能数据平面：

┌─────────────────────────────────────────────────────────────┐
│                    VPP in Kubernetes                        │
│                                                              │
│  数据平面：                                                  │
│  - VPP CNI: Pod 网络                                       │
│  - VPP LBM: Service Load Balancer                         │
│  - VPP Gateway: North-South 流量                          │
│                                                              │
│  控制平面：                                                  │
│  - Kubernetes API Server                                   │
│  - VPP 控制器 (Go)                                         │
│  - CNI plugin                                              │
└─────────────────────────────────────────────────────────────┘
```

## 2. VPP CNI for Kubernetes

### 2.1 VPP CNI 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP CNI 架构                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Kubernetes API Server                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP CNI Plugin                           │  │
│  │                                                       │  │
│  │  - 创建 Tap 接口                                      │  │
│  │  - 分配 IP (via IPAM)                               │  │
│  │  - 配置 routes                                       │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    VPP                               │  │
│  │                                                       │  │
│  │  - Tap 接口                                          │  │
│  │  - Bridge Domain                                    │  │
│  │  - L3 Routing                                       │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 VPP CNI 安装

```bash
# 安装 VPP CNI
kubectl apply -f https://raw.githubusercontent.com/FDio/vpp/master/
build-root/install-vpp-cni.yaml

# 查看 CNI 安装
kubectl get pods -n kube-system | grep vpp

# 查看 VPP pod
kubectl get pods -n kube-system -l app=vpp
```

### 2.3 VPP CNI 配置

```yaml
# vpp-cni-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: vpp-cni-config
  namespace: kube-system
data:
  config: |
    {
      "vppConf": "/etc/vpp/vpp.conf",
      "ipamConf": "/etc/cni/net.d/10-test.conf"
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: vpp-node-agent
  namespace: kube-system
spec:
  hostNetwork: true
  containers:
  - name: vpp-agent
    image: vfiovpp/vpp-agent:latest
    securityContext:
      privileged: true
    volumeMounts:
    - name: cni-bin
      mountPath: /opt/cni/bin
    - name: cni-conf
      mountPath: /etc/cni/net.d
  volumes:
  - name: cni-bin
    hostPath:
      path: /opt/cni/bin
  - name: cni-conf
    hostPath:
      path: /etc/cni/net.d
```

## 3. VPP Service Load Balancer

### 3.1 LBM 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP LBM 架构                           │
│                                                              │
│  Service                                                     │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Type: LoadBalancer                                 │  │
│  │  Selector: app=nginx                                │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP LB Node                              │  │
│  │                                                       │  │
│  │  - 接收外部流量                                       │  │
│  │  - NAT 到后端 Pods                                  │  │
│  │  - 健康检查                                          │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│         ┌────────────────┼────────────────┐               │
│         ↓                ↓                ↓               │
│     Pod:nginx-1      Pod:nginx-2      Pod:nginx-3          │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 VPP LBM 配置

```bash
# 创建 VPP LBM
vpp# lbm create service-1
vpp# lbm add backend service-1 10.244.1.10:80
vpp# lbm add backend service-1 10.244.1.11:80
vpp# lbm set algorithm service-1 round-robin
vpp# lbm enable service-1
```

### 3.3 K8s 集成

```yaml
# service-lbm.yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-lb
  annotations:
    service.beta.kubernetes.io/vpp-lb: "true"
spec:
  type: LoadBalancer
  selector:
    app: nginx
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
```

## 4. VPP Gateway

### 4.1 Gateway 概念

```
VPP Gateway 用于南北流量：

┌─────────────────────────────────────────────────────────────┐
│                    VPP Gateway                             │
│                                                              │
│  External Traffic                                           │
│       │                                                      │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Gateway                              │  │
│  │                                                       │  │
│  │  - NAT (SNAT/DNAT)                                  │  │
│  │  - ACL                                               │  │
│  │  - QoS                                               │  │
│  │  - Routing                                           │  │
│  └──────────────────────────────────────────────────────┘  │
│       │                                                      │
│       ↓                                                      │
│  Pod Network (ClusterIP)                                    │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 VPP Gateway 配置

```bash
# 配置 VPP Gateway
vpp# gateway add external GigabitEthernet0/8/0
vpp# gateway set snat pool 203.0.113.10-203.0.113.20
vpp# gateway enable
```

## 5. Envoy 集成

### 5.1 Envoy 概述

```
Envoy 是高性能 L7 代理：

┌─────────────────────────────────────────────────────────────┐
│                    Envoy 架构                               │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Envoy Proxy                              │  │
│  │                                                       │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐             │  │
│  │  │ Listener │  │  Route   │  │ Cluster  │             │  │
│  │  │         │  │ Table   │  │ Manager  │             │  │
│  │  └─────────┘  └─────────┘  └─────────┘             │  │
│  │                                                       │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐             │  │
│  │  │  Filter │  │   LB    │  │ Health  │             │  │
│  │  │ Chain   │  │         │  │ Check   │             │  │
│  │  └─────────┘  └─────────┘  └─────────┘             │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 VPP + Envoy 架构

```
VPP + Envoy 组合：

┌─────────────────────────────────────────────────────────────┐
│                    VPP + Envoy                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP (L3/L4)                              │  │
│  │                                                       │  │
│  │  - 高速 L3 转发                                       │  │
│  │  - VXLAN 隧道                                        │  │
│  │  - NAT                                               │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Envoy (L7)                               │  │
│  │                                                       │  │
│  │  - HTTP/REST 分析                                    │  │
│  │  - 高级路由                                          │  │
│  │  - 可观测性                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 5.3 Envoy xDS 集成

```yaml
# VPP 通过 xDS 连接 Envoy
apiVersion: v1
kind: ConfigMap
metadata:
  name: envoy-config
data:
  envoy.yaml: |
    static_resources:
      listeners:
      - address:
          socket_address:
            address: 0.0.0.0
            port_value: 80
        filter_chains:
        - filters:
          - name: envoy.filters.network.http_connection_manager
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
              route_config:
                name: local_route
                virtual_hosts:
                - name: backend
                  domains: ["*"]
                  routes:
                  - match: { prefix: "/" }
                    route:
                      cluster: vpp_cluster
      clusters:
      - name: vpp_cluster
        type: STATIC
        lb_policy: ROUND_ROBIN
        load_assignment:
          cluster_name: vpp_cluster
          endpoints:
          - lb_endpoints:
            - endpoint:
                address:
                  socket_address:
                    address: 10.244.1.10
                    port_value: 8080
```

## 6. Service Mesh 集成

### 6.1 Sidecar 模式

```
VPP 可以作为 Service Mesh 的数据平面：

┌─────────────────────────────────────────────────────────────┐
│                    Sidecar 模式                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                         Pod                           │  │
│  │  ┌──────────┐   ┌──────────────────────────────────┐ │  │
│  │  │   App    │◀─▶│        VPP Proxy (Sidecar)       │ │  │
│  │  │  nginx   │   │  - mTLS                         │ │  │
│  │  └──────────┘   │  - L7 routing                   │ │  │
│  │                  │  - Telemetry                    │ │  │
│  │                  └──────────────────────────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 VPP 作为 Sidecar

```yaml
# VPP Sidecar 配置
apiVersion: v1
kind: Pod
metadata:
  name: nginx-with-vpp
  annotations:
    proxy.vpp.io: "true"
    proxy.vpp.mtls: "enabled"
spec:
  containers:
  - name: nginx
    image: nginx
  initContainers:
  - name: vpp-sidecar
    image: vfiovpp/sidecar:latest
```

## 7. 性能对比

### 7.1 kube-proxy vs VPP

| 指标 | kube-proxy (iptables) | VPP LBM |
|------|------------------------|---------|
| **延迟** | ~100-200μs | ~10-30μs |
| **吞吐量** | ~2 Gbps | ~10-15 Gbps |
| **PPS** | ~500K | ~10M |
| **扩展性** | O(n) rules | O(1) lookup |
| **内存** | 高 (many rules) | 低 |

### 7.2 优化建议

```bash
# VPP 节点配置优化
# /etc/vpp/startup.conf
cpu {
    main-core 0
    corelist-workers 1-3
}

dpdk {
    socket-mem 1024,1024
    no-tx-checksum-offload
}
```

## 8. 总结

VPP 在 K8s 中的位置：

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes + VPP                        │
│                                                              │
│  Control Plane (kube-apiserver, etcd)                       │
│          ↓                                                    │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP CNI (Pod 网络)                       │  │
│  │              VPP LBM (Service)                         │  │
│  │              VPP Gateway (Ingress)                     │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Data Plane                           │  │
│  │                                                       │  │
│  │  - L2/L3 转发                                        │  │
│  │  - NAT/Session                                      │  │
│  │  - ACL/QoS                                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

集成方案：

| 组件 | 功能 | 替代 |
|------|------|------|
| **VPP CNI** | Pod 网络 | flannel, calico |
| **VPP LBM** | Service LB | kube-proxy |
| **VPP Gateway** | Ingress | NGINX, Envoy |
| **VPP Sidecar** | Mesh | Istio, Linkerd |

---

## 参考资源

- [VPP Kubernetes](https://wiki.fd.io/view/VPP/Kubernetes)
- [Multus CNI](https://github.com/k8snetworkplumbingwg/multus-cni)
- [Envoy xDS](https://www.envoyproxy.io/docs/envoy/v1.16.0/api-docs/xds_protocol)
