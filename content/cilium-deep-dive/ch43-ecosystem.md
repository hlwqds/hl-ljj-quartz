---
title: "Cilium 深度探索 (43)：Cilium 生态概述"
date: 2026-04-14
tags:
  - cilium
  - ecosystem
  - integration
  - observability
  - hubble
  - prometheus
  - grafana
  - opentelemetry
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 39. [[ch39-install|第三十九章：生产级安装指南]] 40. [[ch40-upgrade|第四十章：升级策略]] 41. [[ch41-debug|第四十一章：故障诊断]] 42. [[ch42-performance|第四十二章：性能调优]] 43. **第四十三章：Cilium 生态概述** ← 44. [[ch44-bgp|第四十四章：BGP 网络集成]] 45. [[ch45-security|第四十五章：安全生态集成]] 46. [[ch46-operator|第四十六章：扩展与 Operator]]

---

## 1. Cilium 生态全景

Cilium 不仅仅是一个 CNI 插件，它是一个围绕 eBPF 的完整云原生网络与安全生态系统。本章介绍 Cilium 与各主要生态项目的集成关系。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Cilium 生态系统全景                              │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      可观测性层                                    │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐   │   │
│   │  │  Hubble   │  │Prometheus │  │  Grafana  │  │ OpenTelemetry│  │   │
│   │  └───────────┘  └───────────┘  └───────────┘  └────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                       网络层                                      │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐   │   │
│   │  │   BGP     │  │  Envoy    │  │ Istio     │  │  Cluster   │   │   │
│   │  │ (CiliumBG │  │ (L7 Proxy)│  │ (Service  │  │   Mesh     │   │   │
│   │  │   P)      │  │           │  │   Mesh)   │  │            │   │   │
│   │  └───────────┘  └───────────┘  └───────────┘  └────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                       安全层                                      │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐   │   │
│   │  │ Cert-     │  │  SPIFFE   │  │ WireGuard │  │  IPsec     │   │   │
│   │  │ Manager   │  │ /SPIRE    │  │ (Encryption│  │ (Encryption│  │   │
│   │  └───────────┘  └───────────┘  └───────────┘  └────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                    基础设施层                                    │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌────────────┐   │   │
│   │  │Kubernetes  │  │  Helm     │  │Terraform  │  │  CSI/CNI   │   │   │
│   │  │  (K8s)    │  │(Chart)    │  │(IaC)      │  │  Plugins   │   │   │
│   │  └───────────┘  └───────────┘  └───────────┘  └────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      核心层 (Cilium)                              │   │
│   │  ┌─────────────────────────────────────────────────────────┐    │   │
│   │  │  eBPF Datapath  │  Hubble  │  Tetragon  │  CLI/GQL API  │    │   │
│   │  └─────────────────────────────────────────────────────────┘    │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 可观测性集成架构

### 2.1 Hubble：内置网络可观测性

Hubble 是 Cilium 原生的网络可观测性平台，提供服务依赖图、流量监控和安全分析能力。

```bash
# Hubble 架构
┌─────────────────────────────────────────────────────────────────────────┐
│                         Hubble 架构                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   eBPF (Cilium Agent)                                                   │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  ┌───────────────┐                                               │   │
│   │  │  eBPF Program  │  →  Flow 生成                                 │   │
│   │  │  (parse_geneve │                                               │   │
│   │  │   , parse_vxla │                                               │   │
│   │  │    n...)       │                                               │   │
│   │  └───────┬───────┘                                               │   │
│   │          │                                                        │   │
│   │          ↓                                                        │   │
│   │  ┌───────────────┐                                               │   │
│   │  │  perf ring     │  →  Unix Socket                              │   │
│   │  │  buffer        │                                               │   │
│   │  └───────┬───────┘                                               │   │
│   └──────────┼──────────────────────────────────────────────────────┘   │
│              │                                                            │
│              ↓                                                            │
│   ┌──────────────────────────────────────────────────────────────────┐    │
│   │                    Hubble Relay                                   │    │
│   │  ┌────────────────────────────────────────────────────────────┐  │    │
│   │  │  gRPC Stream → Flow Aggregation → Metrics生成              │  │    │
│   │  └────────────────────────────────────────────────────────────┘  │    │
│   └──────────────────────────────────────────────────────────────────┘    │
│              │                                                            │
│              ├────────────────────┬────────────────────┐                 │
│              ↓                    ↓                    ↓                 │
│   ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐       │
│   │   Hubble UI      │  │   Hubble CLI    │  │  OpenTelemetry   │       │
│   │   (Web UI)       │  │   (hubble obs)   │  │  (Export)        │       │
│   └──────────────────┘  └──────────────────┘  └──────────────────┘       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Prometheus 指标集成

Cilium 和 Hubble 都暴露 Prometheus 格式的指标：

```bash
# 启用 Prometheus 指标
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set prometheus.metrics.enabled=true \
  --set hubble.metrics.enabled=true \
  --set hubble.metrics.port=9965

# Prometheus 发现配置
# cilium-adminmeric 是 ClusterIPService
kubectl get svc -n kube-system cilium-adminmeric
```

```yaml
# Prometheus Scrape Config
scrape_configs:
  - job_name: "cilium"
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - kube-system
    relabel_configs:
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: cilium-adminmetric

  - job_name: "hubble"
    kubernetes_sd_configs:
      - role: endpoints
        namespaces:
          names:
            - kube-system
    relabel_configs:
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: hubble-metric
```

```bash
# 常用 Cilium 指标
# 节点指标
cilium_agent_subsystem_route_count           # 路由数量
cilium_agent_subsystem_endpoint_count        # 端点数量
cilium_agent_subsystem_identities_count      # 身份数量

# BPF 指标
cilium_bpf_map_hits_total                    # Map 命中数
cilium_bpf_map_misses_total                  # Map 未命中数
cilium_bpf_syscall_duration_seconds          # BPF 系统调用延迟

# 负载均衡器指标
cilium_lb_service_count                      # Service 数量
cilium_lb_backend_count                       # Backend 数量
cilium_lb_conntrack_gc_duration_seconds      # Conntrack GC 时间

# Hubble 指标
hubble_flows_processed_total                 # 处理的 Flow 总数
hubble_http_requests_total                    # HTTP 请求数
hubble_http_responses_total                   # HTTP 响应数
hubble_http_request_duration_seconds         # HTTP 请求延迟
```

### 2.3 Grafana Dashboard

```bash
# 导入 Grafana Dashboard
# Dashboard ID: 16951 (Cilium Overview)
# Dashboard ID: 17507 (Hubble)

# 或使用 cilium-cli 直接导入
cilium metrics install grafana

# 常用 Dashboard
┌─────────────────────────────────────────────────────────────────────────┐
│                      Grafana Dashboard 概览                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Dashboard 1: Cilium Overview                                         │
│   ├── Agent Status (Ready/NotReady)                                    │
│   ├── Endpoint Count by Status                                         │
│   ├── BPF Map Usage                                                    │
│   ├── Service Count                                                     │
│   └── Node-to-Node Connectivity                                         │
│                                                                         │
│   Dashboard 2: Hubble Network Flow                                     │
│   ├── Traffic Volume (bytes/packets)                                   │
│   ├── Flow Rate by Protocol                                            │
│   ├── DNS Query/Response Rate                                          │
│   ├── HTTP Latency P50/P95/P99                                         │
│   └── Dropped Packets                                                   │
│                                                                         │
│   Dashboard 3: Security & Policy                                       │
│   ├── Active Network Policies                                           │
│   ├── DNS Allow/Deny Count                                             │
│   ├── L7 Policy Enforcement                                             │
│   └── TLS Inspection Stats                                             │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 与服务网格生态的集成

### 3.1 Cilium 内置 L7 vs Istio

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    L7 处理方式对比                                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   方式一：Cilium 原生 L7 (Envoy 嵌入式)                                   │
│   ────────────────────────────────────────                             │
│   Pod → eBPF (L3/L4) → Cilium Agent (内置 Envoy) → App                   │
│                                                                         │
│   优势:                                                                  │
│   • 无需 Sidecar Proxy                                                  │
│   • 资源占用少 (~50MB vs ~100MB per Pod)                                │
│   • 配置简单                                                             │
│   • 与网络策略无缝集成                                                   │
│                                                                         │
│   方式二：Istio + Cilium (Cilium 作为 CNI)                               │
│   ─────────────────────────────────────────                             │
│   Pod → Sidecar (Envoy) → eBPF (L3/L4) → Node → ...                    │
│                                                                         │
│   优势:                                                                  │
│   • Istio 完整功能 (mTLS, 策略, 追踪)                                     │
│   • 与现有 Istio 应用兼容                                               │
│   • 社区生态成熟                                                        │
│                                                                         │
│   方式三：Cilium Ambient (零信任网格)                                     │
│   ────────────────────────────────────────                             │
│   Pod → eBPF (L3/L4) → Waypoint Proxy → App                            │
│   (Waypoint 按命名空间/服务部署，非 per-Pod)                              │
│                                                                         │
│   优势:                                                                  │
│   • 介于原生 L7 和 Istio 之间                                            │
│   • 资源占用适中                                                         │
│   • 无需应用修改                                                         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 与 Istio 集成配置

```yaml
# 安装 Cilium 作为 CNI
cilium install --set cni.chainingMode=istio

# Istio 配置
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: cilium-istio
spec:
  profile: default
  components:
    pilot:
      k8s:
        env:
          # 禁用 istiod 安全功能（由 Cilium 处理）
          - name: PILOT_ENABLE_SDS
            value: "false"
          - name: PILOT_ENABLE_TLS_INSPIECTOR
            value: "false"

# 启用 Cilium 集成
apiVersion: cilium.io/v2
kind: CiliumConfig
metadata:
  name: cilium-istio-integration
spec:
  istio:
    enabled: true
```

---

## 4. 安全生态集成

### 4.1 SPIFFE/SPIRE 集成

SPIFFE (Secure Production Identity Framework for Everyone) 提供工作负载身份认证：

```bash
# Cilium 支持 SPIFFE ID 作为策略主体
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: spiffe-auth
spec:
  endpointSelector:
    matchLabels:
      app: secure-api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      authentication:
        # 使用 SPIFFE ID 认证
        spiffe:
          - uriSans:
              - spiffe://cluster.local/ns/default/sa/privileged-workload
```

### 4.2 Cert-Manager 集成

```yaml
# 启用 Cert-Manager 集成
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set certmanager.enabled=true \
  --set certmanager.metrics.enabled=true

# Cilium Gateway API 证书管理
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: external-gateway
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  gatewayClassName: cilium
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Certificate
            name: cilium-external-gateway-cert
```

---

## 5. 云原生存储集成

### 5.1 CSI (Container Storage Interface)

Cilium 不会直接管理存储，但网络策略可以保护存储流量：

```yaml
# 保护 CSI 通信
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: csi-protection
spec:
  endpointSelector:
    matchLabels:
      app: csi-driver
  egress:
    # 允许访问 Kubernetes API
    - toEntities:
        - kube-apiserver
    # 允许 CSI RPC 通信
    - toPorts:
        - ports:
            - port: "50051"
              protocol: TCP
          listeners:
            - logLevel: DEBUG
              protocol: CSI

# 保护使用存储的 Pod
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: storage-access
spec:
  endpointSelector:
    matchLabels:
      app: mysql
  egress:
    # 允许访问 CSI Provider
    - toEndpoints:
        - matchLabels:
            k8s-app: cilium-csi
      toPorts:
        - port: "50051"
          protocol: TCP
```

---

## 6. 基础设施集成

### 6.1 Kubernetes 生态

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    Kubernetes 集成层级                                   │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   CNI 层                                                                 │
│   ├── kube-controller-manager (服务-account-token-controller)           │
│   ├── kubelet (Pod 网络配置)                                             │
│   └── kube-proxy (备用，不推荐与 Cilium 共存)                             │
│                                                                         │
│   网络插件                                                                 │
│   ├── Cilium CNI (主)                                                    │
│   └── CNI Chaining (与其他插件如 aws-cni, calico 链式)                    │
│                                                                         │
│   网络策略                                                                │
│   ├── CiliumNetworkPolicy (CRD)                                         │
│   ├── NetworkPolicy (K8s 原生)                                          │
│   └── Gateway API (/networking.k8s.io)                                  │
│                                                                         │
│   服务发现                                                                │
│   ├── kube-dns / CoreDNS                                                │
│   └── Cilium Cluster DNS (Cilium 自己的 DNS 代理)                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.2 Terraform IaC 集成

```hcl
# Terraform 中的 Cilium 资源配置
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  namespace  = "kube-system"

  set {
    name  = "k8sServiceHost"
    value = var.k8s_api_server
  }

  set {
    name  = "k8sServicePort"
    value = var.k8s_api_port
  }

  set {
    name  = "prometheus.metrics.enabled"
    value = "true"
  }

  set {
    name  = "hubble.enabled"
    value = "true"
  }

  set {
    name  = "hubble.metrics.enabled"
    value = "true"
  }

  set {
    name  = "ipam.mode"
    value = "cluster-pool"
  }

  # AWS EKS 特定配置
  set {
    name  = "nodeinit.enabled"
    value = "true"
  }

  set {
    name  = "tunnel"
    value = "aws-eni"
  }
}
```

---

## 7. 生态集成检查清单

### 7.1 部署前检查

```bash
# 1. 内核版本要求
uname -r  # 需要 >= 5.10 (推荐 5.15+)

# 2. 检查 eBPF 支持
cilium diagnose check --pre-check

# 3. 检查 Kubernetes 版本
kubectl version --short

# 4. 确认容器运行时
crictl --version

# 5. 检查 iptables 模式
# Cilium 需要 nft 或 iptables-legacy
iptables --version
```

### 7.2 集成验证

```bash
# 验证 Hubble 连通性
hubble status

# 验证 Prometheus 指标
curl -s http://localhost:9965/metrics | head -20

# 验证 Grafana Dashboard
kubectl get configmap -n kube-system grafana-cilium-dashboards

# 验证 Cilium CLI
cilium status --wait

# 验证网络策略
cilium policy get
```

---

## 8. 生态组件版本兼容性

| 组件         | 最低版本 | 推荐版本 | 说明                    |
| :----------- | :------- | :------- | :---------------------- |
| Kubernetes   | 1.16     | 1.25+    | Gateway API 需要 1.19+  |
| Linux Kernel | 5.10     | 5.15+    | Host Routing 需要 5.10+ |
| Helm         | 3.6      | 3.10+    |                         |
| Cilium CLI   | 0.12     | 最新     |                         |
| Hubble CLI   | 0.11     | 最新     |                         |
| Prometheus   | 2.40     | 2.45+    |                         |
| Grafana      | 8.5      | 9.0+     | Dashboard 需 v8.5+      |

---

## 9. 总结

Cilium 的生态系统覆盖了云原生网络、安全和可观测性的各个方面：

1. **可观测性**：Hubble 提供内置的流量可视化，Prometheus/Grafana 提供指标监控
2. **服务网格**：支持原生 L7、Ambient 模式和 Istio 集成
3. **安全**：与 SPIFFE、Cert-Manager、WireGuard/IPsec 深度集成
4. **基础设施**：支持 Kubernetes、Terraform、Helm 等主流工具

下一章我们将深入探讨 Cilium 的 BGP 网络集成，了解 Cilium 如何与外部网络设备协同工作。
