---
title: "Cilium 深度探索 (45)：安全生态集成"
date: 2026-04-14
tags:
  - cilium
  - security
  - tls
  - mtls
  - pki
  - cert-manager
  - spiffe
  - wireguard
  - ipsec
  - encryption
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 42. [[ch42-performance|第四十二章：性能调优]] 43. [[ch43-ecosystem|第四十三章：Cilium 生态概述]] 44. [[ch44-bgp|第四十四章：BGP 网络集成]] 45. **第四十五章：安全生态集成** ← 46. [[ch46-operator|第四十六章：扩展与 Operator]]

---

## 1. 安全生态概览

Cilium 在安全方面与多个生态系统深度集成，提供从网络层到应用层的全方位安全能力：

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Cilium 安全层次架构                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                     应用层安全                                    │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐                   │   │
│   │  │  mTLS    │  │   L7     │  │   SPIFFE  │                   │   │
│   │  │(Identity)│  │  Policy  │  │  /SPIRE   │                   │   │
│   │  └───────────┘  └───────────┘  └───────────┘                   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                     传输层安全                                    │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐                   │   │
│   │  │   TLS    │  │Cert-Manager│  │  WireGuard │                   │   │
│   │  │Inspection │  │  Integration│  │  (5.6+)  │                   │   │
│   │  └───────────┘  └───────────┘  └───────────┘                   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                     网络层安全                                    │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐                   │   │
│   │  │   IPsec  │  │ Network   │  │   Egress  │                   │   │
│   │  │(Hardware)│  │  Policy   │  │  Gateway  │                   │   │
│   │  └───────────┘  └───────────┘  └───────────┘                   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                     数据面安全                                    │   │
│   │  ┌───────────┐  ┌───────────┐  ┌───────────┐                   │   │
│   │  │   eBPF   │  │   Tetragon │  │   Seccomp │                   │   │
│   │  │ (Runtime)│  │ (Runtime) │  │  (Sandbox)│                   │   │
│   │  └───────────┘  └───────────┘  └───────────┘                   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 传输加密

### 2.1 WireGuard 加密

WireGuard 是现代的轻量级 VPN 协议，内核 5.6+ 原生支持：

```bash
# 启用 WireGuard 加密
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set wireguard.enabled=true

# 验证 WireGuard 状态
cilium encrypt status

# 示例输出
# Encryption: WireGuard (0.0.0.0)
# └─ NodeEncryption: Enabled
#    ├─ Type: WireGuard
#    └─ Keys: 1 active, 1 queued
```

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       WireGuard 加密流程                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Node A                                Node B                           │
│   ┌─────────────────┐                 ┌─────────────────┐               │
│   │   Pod           │                 │   Pod           │               │
│   │   │             │                 │   │             │               │
│   │   ▼             │                 │   ▼             │               │
│   │ ┌─────────────┐ │                 │ ┌─────────────┐ │               │
│   │ │ eBPF (TX)  │ │                 │ │ eBPF (RX)  │ │               │
│   │ │  Encrypt    │ │                 │ │  Decrypt    │ │               │
│   │ └──────┬──────┘ │                 │ └──────┬──────┘ │               │
│   │        │        │                 │        │        │               │
│   │        ▼        │                 │        │        │               │
│   │ ┌─────────────┐ │    Encrypted    │ ┌─────────────┐ │               │
│   │ │ WireGuard   │ │◄───────────────►│ │ WireGuard   │ │               │
│   │ │   Device    │ │   UDP 51871     │ │   Device    │ │               │
│   │ └──────┬──────┘ │                 │ └──────┬──────┘ │               │
│   │        │        │                 │        │        │               │
│   └────────┼────────┘                 └────────┼────────┘               │
│            │                                       │                     │
│            └───────────── Physical Network ────────┘                   │
│                                                                         │
│   WireGuard 包格式:                                                     │
│   ┌────────┬──────────────────────────────────────────────────┐        │
│   │IP Header│  UDP (51871)  │  WireGuard Header  │  Encrypted │        │
│   └────────┴──────────────────────────────────────────────────┘        │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 IPsec 加密

对于不支持 WireGuard 的内核，可以使用 IPsec：

```bash
# 启用 IPsec 加密
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set encryption.enabled=true \
  --set encryption.type=ipsec

# IPsec 模式
# IPsec 加密需要启用 NAT
--set encryption.nodeEncryption=true
# 或
--set encryption.enabled=true --set encryption.ipsec.mountICMPv6Headers=true

# 查看 IPsec 状态
cilium encrypt status

# 示例输出
# Encryption: IPsec
# └─ NodeEncryption: Enabled
#    ├─ Type: IPsec
#    └─ Keys: 1 active, 1 queued
```

### 2.3 加密比较

| 特性       | WireGuard | IPsec    |
| :--------- | :-------- | :------- |
| 内核要求   | 5.6+      | 4.19+    |
| 性能       | 更高      | 较高     |
| 硬件卸载   | 部分支持  | 完整支持 |
| 配置复杂度 | 简单      | 中等     |
| 兼容性     | 较新      | 广泛     |

---

## 3. PKI 与证书管理

### 3.1 Cert-Manager 集成

Cilium 与 cert-manager 深度集成，支持自动证书管理：

```bash
# 安装 cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.0/cert-manager.yaml

# 为 Cilium 颁发证书
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cilium-ca
spec:
  ca:
    secretName: cilium-ca-key-pair

---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cilium-cert
  namespace: kube-system
spec:
  secretName: cilium-cert-tls
  isCA: true
  issuerRef:
    name: cilium-ca
    kind: ClusterIssuer
  commonName: cilium-operator
  dnsNames:
    - cilium-operator.kube-system.svc.cluster.local
```

### 3.2 Cilium 证书配置

```yaml
# Cilium TLS 配置
apiVersion: cilium.io/v2
kind: CiliumConfig
metadata:
  name: cilium-tls-config
spec:
  # Hubble mTLS
  hubble:
    tls:
      enabled: true
      caCert: |
        -----BEGIN CERTIFICATE-----
        ...
        -----END CERTIFICATE-----
      server:
        cert: |
          -----BEGIN CERTIFICATE-----
          ...
          -----END CERTIFICATE-----
        key: |
          -----BEGIN PRIVATE KEY-----
          ...
          -----END PRIVATE KEY-----

  # Agent TLS
  agent:
    tls:
      server:
        enabled: true
        cert: /var/run Cilium/certs/server.crt
        key: /var/run/cilium/certs/server.key
```

---

## 4. mTLS 与身份认证

### 4.1 SPIFFE/SPIRE 集成

SPIFFE (Secure Production Identity Framework for Everyone) 提供标准化的工作负载身份：

```bash
# 安装 SPIRE Server 和 Agent
helm install spire spire \
  --namespace spire \
  --set spire-server.enabled=true \
  --set spire-agent.enabled=true \
  --set agent.joinToken.enabled=true

# 创建 join token
kubectl exec -n spire spire-server-0 -- \
  /opt/spire/bin/spire-server token generate \
  --spiffeID spiffe://cluster.local/ns/spire/sa/spire-agent

# Cilium 策略中使用 SPIFFE ID
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: spiffe-mtls
spec:
  endpointSelector:
    matchLabels:
      app: api-server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      authentication:
        spiffe:
          - uriSans:
              - spiffe://cluster.local/ns/default/sa/frontend
```

### 4.2 Cilium 身份模型

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Cilium 身份模型                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Identity = Kubernetes Workload (Pod) + Security Labels               │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                     Identity Level                              │   │
│   │                                                                  │   │
│   │   Pod: nginx-abc123                                            │   │
│   │   Namespace: default                                            │   │
│   │   Labels:                                                       │   │
│   │     app: nginx                                                  │   │
│   │     version: v1                                                  │   │
│   │     tier: frontend                                              │   │
│   │                                                                  │   │
│   │   ↓ ↓ ↓                                                          │   │
│   │   哈希 → Identity ID (numeric)                                  │   │
│   │                                                                  │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   Identity 存储位置:                                                     │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  cilium_identity (BPF Map)                                      │   │
│   │  ┌─────────────┬────────────┬─────────────────────────────┐    │   │
│   │  │  ID         │  RefCount  │  Labels                      │    │   │
│   │  ├─────────────┼────────────┼─────────────────────────────┤    │   │
│   │  │  44352      │  3         │  k8s:app=nginx;...          │    │   │
│   │  │  44353      │  2         │  k8s:app=redis;...          │    │   │
│   │  └─────────────┴────────────┴─────────────────────────────┘    │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.3 L7 mTLS 配置

```yaml
# 启用 L7 mTLS
apiVersion: cilium.io/v2
kind: CiliumL7Policy
metadata:
  name: api-mtls
spec:
  endpointSelector:
    matchLabels:
      app: api-server
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: client
      authentication:
        mTLS:
          # 要求双向 TLS
          mode: required
          # 信任域
          trustDomain: cluster.local
      http:
        - method: GET
          path: /api/v1/
        - method: POST
          path: /api/v1/data
```

---

## 5. 网络策略与安全

### 5.1 策略类型

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Cilium 策略层级                                    │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Layer 7 (L7) - 应用层                                            │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  HTTP: method, path, headers                                │ │   │
│   │  │  Kafka: topic, action                                      │ │   │
│   │  │  DNS: query types, domain                                  │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Layer 4 (L4) - 传输层                                            │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  TCP/UDP: port, protocol                                    │ │   │
│   │  │  +ToPorts (e.g., HTTP 80, gRPC 50051)                      │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Layer 3 (L3) - 网络层                                            │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  toEndpoints: label selector                               │ │   │
│   │  │  toCIDR: CIDR notation                                      │ │   │
│   │  │  toCIDRSet: CIDR with per-prefix limits                     │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Layer 2 (L2) - 数据链路层                                        │   │
│   │  ┌─────────────────────────────────────────────────────────────┐ │   │
│   │  │  toPorts: protocol-specific (e.g., ICMP)                   │ │   │
│   │  │  l2Policy: MAC-based (很少使用)                              │ │   │
│   │  └─────────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 5.2 CNP 与 CCNP

```yaml
# Cluster-wide CiliumNetworkPolicy (CCNP)
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: cluster-wide-deny-external
spec:
  # 对所有命名空间生效
  nodeSelector: {}
  egress:
    # 拒绝所有外部流量
    - toEntities:
        - remote-node
        - world
      # 但允许 DNS
      except:
        - toPorts:
            - ports:
                - port: "53"
                  protocol: UDP

---
# 命名空间级别 CiliumNetworkPolicy (CNP)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
        - protocol: HTTP
          method: "GET"
          path: "/api/.*"
```

### 5.3 策略示例

```yaml
# 完整的零信任策略示例
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: zero-trust-web
spec:
  endpointSelector:
    matchLabels:
      app: webapp
      tier: frontend
  ingress:
    # 允许来自 Ingress Gateway 的流量
    - fromEntities:
        - ingress
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
        - protocol: HTTP
    # 允许来自前端命名空间
    - fromNamespace:
        matchLabels:
          namespace: frontend
    # 拒绝其他所有
  egress:
    # 允许 DNS
    - toPorts:
        - ports:
            - port: "53"
              protocol: UDP
    # 允许 Kubernetes API
    - toEntities:
        - kube-apiserver
    # 允许特定后端服务
    - toEndpoints:
        - matchLabels:
            app: api
            tier: backend
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
        - protocol: HTTP
    # 允许外部 API (白名单)
    - toFQDNs:
        - matchName: api.stripe.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
    # 拒绝其他所有出口
```

---

## 6. Tetragon 安全监控

Tetragon 是 Cilium 的运行时安全项目，提供基于 eBPF 的实时威胁检测：

```bash
# 启用 Tetragon
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set tetragon.enabled=true \
  --set tetragon.export.enable=true

# Tetragon 架构
┌─────────────────────────────────────────────────────────────────────────┐
│                       Tetragon 架构                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  eBPF Probes (Kernel)                                            │   │
│   │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐            │   │
│   │  │ exec_probe  │  │ net_probe   │  │ file_probe  │            │   │
│   │  │ (syscall)   │  │ (connect)   │  │ (open)      │            │   │
│   │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘            │   │
│   │         │                │                │                     │   │
│   └─────────┼────────────────┼────────────────┼─────────────────────┘   │
│             │                │                │                         │
│             └────────────────┼────────────────┘                         │
│                              │                                          │
│                              ▼                                          │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Tracing Ring Buffer                                            │   │
│   │  (perf event channel)                                           │   │
│   └─────────────────────────────┬───────────────────────────────────┘   │
│                                  │                                       │
│                                  ▼                                       │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │  Tetragon Agent (User Space)                                    │   │
│   │  ┌─────────────────────────────────────────────────────────┐   │   │
│   │  │  Event Filter → Policy Engine → Action (kill/notify)     │   │   │
│   │  └─────────────────────────────────────────────────────────┘   │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                  │                                       │
│                                  ├────────────────┐                       │
│                                  ▼                ▼                       │
│   ┌──────────────────┐   ┌──────────────────┐   ┌──────────────────┐      │
│   │  JSON Log        │   │  Stdout (k8s)    │   │  gRPC Export     │      │
│   └──────────────────┘   └──────────────────┘   └──────────────────┘      │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.1 Tetragon 策略

```yaml
# Tracing Policy 示例
apiVersion: cilium.io/v2alpha1
kind: CiliumTracingPolicy
metadata:
  name: network-violation
spec:
  kprobes:
    - call: "inet_release"
      syscall: false
      return: false
      selectorus:
        matchArgs:
          - index: 0
            operator: Equal
            values:
              - type=SOCK
      matchActions:
        - call: "inet_dgram_release"
          argselus:
            - index: 0
          action: Post
```

---

## 7. Egress Gateway

Egress Gateway 提供出口流量控制和安全：

```bash
# 启用 Egress Gateway
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set egressGateway.enabled=true \
  --set bpf.lbEgressDestinationMark=1

# Egress Gateway 架构
┌─────────────────────────────────────────────────────────────────────────┐
│                    Egress Gateway 架构                                  │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   Pod (10.0.1.100) ──────────────────────────► External Service          │
│       │                                           │                       │
│       │ Egress Policy:                            │                       │
│       │  "app=nginx" → Egress Node 192.168.1.10   │                       │
│       │                                           │                       │
│       ▼                                           ▼                       │
│   ┌─────────────────────────────────────────────────────────────────┐   │
│   │                      Node 192.168.1.10                          │   │
│   │  ┌───────────────────────────────────────────────────────────┐ │   │
│   │  │ eBPF (egressgw)                                           │ │   │
│   │  │  • 捕获出口流量                                           │ │   │
│   │  │  • 替换源 IP 为 Node IP                                   │ │   │
│   │  │  • 记录日志 (可选)                                         │ │   │
│   │  └───────────────────────────────────────────────────────────┘ │   │
│   └─────────────────────────────────────────────────────────────────┘   │
│                                    │                                     │
│                                    ▼                                     │
│                         External Network                                 │
│                                                                         │
│   优势:                                                                  │
│   • 外部服务看到的是固定 Node IP，便于防火墙规则                           │
│   • 所有出口流量经过同一节点，符合合规要求                                │
│   • 支持故障转移                                                          │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 7.1 Egress Gateway 配置

```yaml
# Egress Gateway Policy
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: egress-nginx
spec:
  # 源 Pod 选择器
  sourceSelector:
    matchLabels:
      app: nginx
      tier: frontend
  # 出口节点选择器
  gatewaySelector:
    matchLabels:
      egress: "true"
      # 或指定特定节点
      # nodeName: node-1
  # 目标 CIDR (可选，默认所有外部流量)
  destinationCIDRs:
    - "0.0.0.0/0"
  # 出口 IP (可选，默认使用节点 IP)
  egressIP:
    - "10.244.0.100"
  # 排除某些目的地
  excludedCIDRs:
    - "10.0.0.0/8" # 集群内部
```

---

## 8. 节点间加密配置

```bash
# 完整的加密配置
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set encryption.enabled=true \
  --set encryption.type=wireguard \
  --set encryption.nodeEncryption=true \
  --set encryption.ipsec.keyFile=/etc/kubernetes/pki/ipsec.key \
  --set encryption.ipsec.certFile=/etc/kubernetes/pki/ipsec.crt

# 查看加密状态
cilium encrypt status

# 验证加密
tcpdump -i cilium+ -n | grep -i wireguard
# 或
tcpdump -i cilium+ -n | grep -i esp
```

---

## 9. 安全检查清单

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      Cilium 安全检查清单                                 │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│   □ 传输加密                                                             │
│     ├─ WireGuard (内核 5.6+) 或 IPsec                                    │
│     ├─ 节点间加密已启用                                                   │
│     └─ 定期轮换密钥                                                      │
│                                                                         │
│   □ 身份与认证                                                            │
│     ├─ SPIFFE/SPIRE 集成 (如需要 mTLS)                                  │
│     ├─ Cert-Manager 集成                                                │
│     └─ Hubble mTLS (如使用 Hubble Relay)                               │
│                                                                         │
│   □ 网络策略                                                              │
│     ├─ 默认拒绝所有 (implicitly Deny)                                   │
│     ├─ 最小权限原则                                                      │
│     ├─ L7 策略 (HTTP/Kafka/DNS)                                        │
│     └─ Egress 白名单                                                     │
│                                                                         │
│   □ 运行时安全                                                            │
│     ├─ Tetragon 已部署                                                   │
│     ├─ 关键进程监控                                                      │
│     └─ 异常行为告警                                                       │
│                                                                         │
│   □ 合规                                                                  │
│     ├─ 审计日志                                                          │
│     ├─ 密钥轮换策略                                                       │
│     └─ 网络流量加密                                                       │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 10. 总结

Cilium 的安全生态系统提供了纵深防御能力：

1. **传输加密**：WireGuard/IPsec 保护节点间流量
2. **身份认证**：SPIFFE/SPIRE 和 cert-manager 集成
3. **策略执行**：L3-L7 网络策略实现微隔离
4. **运行时安全**：Tetragon 提供 eBPF 驱动的威胁检测
5. **出口控制**：Egress Gateway 精细化出口流量管理

下一章我们将探讨 Cilium 的扩展性与 Operator 开发。
