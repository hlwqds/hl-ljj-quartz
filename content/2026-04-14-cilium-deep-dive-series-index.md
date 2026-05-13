---
title: "Cilium 云原生网络深度探索系列索引"
date: 2026-04-14
pin: true
description: "Cilium 云原生网络深度探索全系列——从 eBPF 数据面、Kubernetes CNI、Hubble 观测、Cilium Cluster Mesh 多集群、Gateway API、Ambient Mode 无 Sidecar、eBPF 限速与网络策略，到生产级部署与排错，40+ 章节系统性解析新一代云原生网络"
tags:
  - cilium
  - series
  - networking
  - cloud-native
  - ebpf
  - kubernetes
  - service-mesh
  - cncf
---

# Cilium 云原生网络深度探索系列

> [!tip] 系列说明
> 本系列约 40+ 篇文章，从 Cilium 诞生背景（替代 kube-proxy 的 eBPF 方案）出发，系统讲解 Cilium 架构（eBPF 数据面/CCN/CNCM）、K8s CNI 集成、Hubble 观测（Flow 可视化/L7 策略）、Cluster Mesh 多集群网络、Cilium Ingress/Gateway API、Ambient Mode（无 Sidecar 零信任）、eBPF 限速与 QoS、网络策略（CiliumNetworkPolicy/NetworkPolicy）、Envoy 集成、生产级部署与排错。
>
> 配合 [[2026-04-13-ebpf-deep-dive-series-index|eBPF 系列]]（eBPF 基础）和 [[2026-04-13-kubernetes-network-series-index|Kubernetes 网络系列]]，构成完整的"云原生网络"知识体系。

---

## Part I：Cilium 基础 (Fundamentals)

理解 Cilium 的设计理念与 eBPF 数据面优势。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 1 | [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|Cilium 概述]] | 诞生背景、eBPF 数据面、Kubernetes CNI | ✅ |
| 2 | [[2026-04-14-cilium-deep-dive-ch2-architecture|Cilium 架构]] | CCN/CNCM/eBPF Datapath/控制面 | ✅ |
| 3 | [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|eBPF 数据面]] | eBPF Hook/Socket 转发/Host Routing | ✅ |
| 4 | [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|Kube-Proxy 替代]] | Kube-Proxy vs Cilium/全功能服务负载均衡 | ✅ |
| 5 | [[2026-04-14-cilium-deep-dive-ch5-cni|CNI 集成]] | CNI 规范、Chaining Mode、Standalone 模式 | ✅ |

---

## Part II：网络功能 (Networking)

Cilium 的核心网络功能。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 6 | [[2026-04-14-cilium-deep-dive-ch6-clusterip|ClusterIP]] | ClusterIP 分配、eBPF Service 映射、Session 亲和 | ✅ |
| 7 | [[2026-04-14-cilium-deep-dive-ch7-nodeport|NodePort]] | NodePort 外部访问、eBPF DSR 直连返回 | ✅ |
| 8 | [[2026-04-14-cilium-deep-dive-ch8-loadbalancer|LoadBalancer]] | L2/L4 LB、Type=LoadBalancer、MetalLB 集成 | ✅ |
| 9 | [[2026-04-14-cilium-deep-dive-ch9-externalip|ExternalIP]] | ExternalIP 路由、Ingress Controller | ✅ |
| 10 | [[2026-04-14-cilium-deep-dive-ch10-vxlan|VXLAN]] | VXLAN Tunnel、Overlay 网络、跨节点 Pod 通信 | ✅ |

---

## Part III：网络策略 (NetworkPolicy)

Cilium 的安全策略体系。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 11 | [[2026-04-14-cilium-deep-dive-ch11-cnp|CiliumNetworkPolicy]] | L3/L4/L7 策略、Endpoint 隔离、DNS 策略 | ✅ |
| 12 | [[2026-04-14-cilium-deep-dive-ch12-networkpolicy|NetworkPolicy]] | K8s NetworkPolicy、Cilium 增强、CIDR 策略 | ✅ |
| 13 | [[2026-04-14-cilium-deep-dive-ch13-layer7|L7 策略]] | L7 HTTP/REST/gRPC 策略、SQL 注入防护 | ✅ |
| 14 | [[2026-04-14-cilium-deep-dive-ch14-dns|DNS 策略]] | DNS 劫持、FQDN 策略、基于 DNS 的分段 | ✅ |
| 15 | [[2026-04-14-cilium-deep-dive-ch15-categories|策略层级]] | Layer 3/4/7 策略、Default Deny/Allow、审计日志 | ✅ |

---

## Part IV：Hubble 观测 (Observability)

Hubble 可观测性平台。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 16 | [[2026-04-14-cilium-deep-dive-ch16-hubble-overview|Hubble 概述]] | Hubble 架构、Flow 可视化、实时网络观测 | ✅ |
| 17 | [[2026-04-14-cilium-deep-dive-ch17-hubble-cli|Hubble CLI]] | Hubble CLI 流量监控、Service Graph | ✅ |
| 18 | [[2026-04-14-cilium-deep-dive-ch18-hubble-ui|Hubble UI]] | Web UI 可视化、Namespace/Pod 视角 | ✅ |
| 19 | [[2026-04-14-cilium-deep-dive-ch19-prometheus|Prometheus]] | Hubble Metrics、Grafana Dashboard | ✅ |
| 20 | [[2026-04-14-cilium-deep-dive-ch20-otel|OpenTelemetry]] | Hubble + OpenTelemetry、分布式 Trace | ✅ |

---

## Part V：Cluster Mesh (Multi-Cluster)

Cilium 多集群网络。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 21 | [[2026-04-14-cilium-deep-dive-ch21-cluster-mesh|Cluster Mesh]] | 多集群网络、Pod CIDR 冲突解决 | 🚧 |
| 22 | [[2026-04-14-cilium-deep-dive-ch22-global-services|Global Services]] | 跨集群 Service 访问、Failover | 🚧 |
| 23 | [[2026-04-14-cilium-deep-dive-ch23-cni|CNI Chain]] | CNI Chaining、Flannel/Calico 集成 | 🚧 |
| 24 | [[2026-04-14-cilium-deep-dive-ch24-ipam|IPAM]] | IPAM 策略、Pod CIDR 分配、IP 预留 | 🚧 |
| 25 | [[2026-04-14-cilium-deep-dive-ch25-etcd|etcd]] | kvstore 部署、可靠性、高可用 | 🚧 |

---

## Part VI：Ingress 与 Gateway API

Cilium 入流量控制。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 26 | [[2026-04-14-cilium-deep-dive-ch26-ingress|Ingress]] | Cilium Ingress Controller、TLS 终止 | ✅ |
| 27 | [[2026-04-14-cilium-deep-dive-ch27-gateway-api|Gateway API]] | Gateway API 标准、HTTPRoute/GRPCRoute | ✅ |
| 28 | [[2026-04-14-cilium-deep-dive-ch28-ingress-annotations|Ingress 注解]] | 负载均衡策略、流量分割、CORS | ✅ |
| 29 | [[2026-04-14-cilium-deep-dive-ch29-cert-manager|Cert Manager]] | TLS 自动化、Let's Encrypt 集成 | ✅ |
| 30 | [[2026-04-14-cilium-deep-dive-ch30-multitenancy|多租户]] | 多租户隔离、Tenant 级别策略 | ✅ |

---

## Part VII：Ambient Mode (Sidecarless)

Cilium Ambient Mode 无 Sidecar 零信任网格。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 31 | [[2026-04-14-cilium-deep-dive-ch31-ambient-overview|Ambient 概述]] | Ambient Mode 架构、Waypoint Proxy | 🚧 |
| 32 | [[2026-04-14-cilium-deep-dive-ch32-waypoint|Waypoint]] | Waypoint Proxy、身份感知路由 | 🚧 |
| 33 | [[2026-04-14-cilium-deep-dive-ch33-l4-l7-ambient|L4/L7 策略]] | Ambient 模式下 L4/L7 策略应用 | 🚧 |
| 34 | [[2026-04-14-cilium-deep-dive-ch34-migration|迁移]] | 从 Sidecar 迁移到 Ambient 模式 | 🚧 |

---

## Part VIII：eBPF 高级 (eBPF Advanced)

eBPF 在 Cilium 中的高级用法。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 35 | [[2026-04-14-cilium-deep-dive-ch35-bandwidth-manager|带宽管理]] | eBPF 限速、FQ PIE 调度、Cilium Bandwidth Manager | 🚧 |
| 36 | [[2026-04-14-cilium-deep-dive-ch36-node-encryption|节点加密]] | WireGuard/IPsec 端到端加密、加密节点 | 🚧 |
| 37 | [[2026-04-14-cilium-deep-dive-ch37-transparent-encryption|透明加密]] | Transparent Encryption、加密策略 | 🚧 |
| 38 | [[2026-04-14-cilium-deep-dive-ch38-sockmap|Sockmap]] | Socket 劫持、TCP 连接优化、进程级过滤 | 🚧 |

---

## Part IX：部署与排错 (Operations)

生产级部署与故障诊断。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 39 | [[2026-04-14-cilium-deep-dive-ch39-install|安装]] | helm/kubectl 安装、配置选项、版本选择 | ✅ |
| 40 | [[2026-04-14-cilium-deep-dive-ch40-upgrade|升级]] | 滚动升级、ConfigMap 迁移、数据面重启 | ✅ |
| 41 | [[2026-04-14-cilium-deep-dive-ch41-debug|排错]] | cilium CLI、Hubble Flow、常见问题 | ✅ |
| 42 | [[2026-04-14-cilium-deep-dive-ch42-performance|性能]] | eBPF 性能基准、延迟优化、吞吐量调优 | ✅ |

---

## Part X：生态与对比 (Ecosystem)

Cilium 生态与竞品对比。

| # | 章节 | 主题 | 状态 |
|---|------|------|------|
| 43 | [[2026-04-14-cilium-deep-dive-ch43-istio|Istio 集成]] | Cilium + Istio、Sidecar vs Ambient | 🚧 |
| 44 | [[2026-04-14-cilium-deep-dive-ch44-linkerd|Linkerd]] | Linkerd + Cilium 对比 | 🚧 |
| 45 | [[2026-04-14-cilium-deep-dive-ch45-calico|Cilium vs Calico]] | eBPF vs Calico 网络策略对比 | 🚧 |
| 46 | [[2026-04-14-cilium-deep-dive-ch46-future|Cilium 未来]] | Cilium 版本演进、Tetragon、CNCF 生态 | 🚧 |

---

## 相关系列

- [[2026-04-13-ebpf-deep-dive-series-index|eBPF 深度探索系列]] — eBPF 基础
- [[2026-04-09-dpdk-deep-dive-series-index|DPDK 深度探索系列]] — 用户态数据包处理
- [[2026-04-14-p4-deep-dive-series-index|P4 深度探索系列]] — 可编程数据面
- [[2026-04-14-srv6-deep-dive-series-index|SRv6 深度探索系列]] — 网络编程
