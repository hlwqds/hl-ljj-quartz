---
title: Cilium 混合加密策略：跨节点 WireGuard + 同节点 mTLS
date: 2026-03-12
tags: [cilium, wireguard, mtls, encryption, zero-trust, performance]
---

> [!abstract] 方案概述
> 通过混合加密策略实现性能与安全的最佳平衡：
>
> - **跨节点流量**：仅 WireGuard 加密（网络层）
> - **同节点流量**：仅 mTLS 加密（应用层）
>
> **收益**：避免双重加密开销，总开销降至 ~5%（对比全双开 10-15%）

---

## 1. 方案背景

### 1.1 问题：双重加密的冗余

```
传统方案（全双开）：

同节点 Pod A → Pod B：
┌─────────────────────────────────────────────────┐
│ App A → eBPF(mTLS加密) → eBPF(mTLS解密) → App B │
│         开销: 5-8%                              │
└─────────────────────────────────────────────────┘

跨节点 Pod A → Pod C：
┌─────────────────────────────────────────────────┐
│ App A → eBPF(mTLS) → WireGuard(再加密) → 网络   │
│         开销: 5-8%    + 开销: 3-5%              │
│         总开销: 8-13%（双重加密冗余）            │
└─────────────────────────────────────────────────┘

问题：
├─ 跨节点流量被加密两次
├─ CPU 开销叠加
└─ 延迟叠加
```

### 1.2 解决方案：混合加密策略

```
优化方案（混合策略）：

同节点 Pod A → Pod B：
┌─────────────────────────────────────────────────┐
│ App A → eBPF(mTLS加密) → eBPF(mTLS解密) → App B │
│         开销: 5-8%                              │
│         ✓ 同节点加密保证                        │
└─────────────────────────────────────────────────┘

跨节点 Pod A → Pod C：
┌─────────────────────────────────────────────────┐
│ App A → 明文 → WireGuard(加密) → 网络 → 解密 → App C│
│         开销: 3-5%                              │
│         ✓ 跨节点加密保证                        │
│         ✓ 无双重加密冗余                        │
└─────────────────────────────────────────────────┘

优势：
├─ 所有流量都被加密（无盲区）
├─ 无双重加密冗余
└─ 总开销: ~5%（优化 50%+）
```

---

## 2. 架构设计

### 2.1 整体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         混合加密架构                                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  Node A                                              Node B             │
│  ┌────────────────────────────────────┐              ┌────────────────┐ │
│  │                                    │              │                │ │
│  │  Pod A (app=frontend)              │              │ Pod C          │ │
│  │  ┌──────────────────────────────┐  │              │ (app=backend)  │ │
│  │  │ App send("request")          │  │              │                │ │
│  │  └─────────────┬────────────────┘  │              └───────▲────────┘ │
│  │                │                    │                      │          │
│  │                ▼                    │                      │          │
│  │  ┌──────────────────────────────┐  │                      │          │
│  │  │ 场景判断                      │  │                      │          │
│  │  │ 目标: Pod B (同节点)          │  │                      │          │
│  │  │ 目标: Pod C (跨节点)          │  │                      │          │
│  │  └─────────────┬────────────────┘  │                      │          │
│  │                │                    │                      │          │
│  │       ┌────────┴────────┐          │                      │          │
│  │       ▼                 ▼          │                      │          │
│  │  ┌─────────────┐  ┌─────────────┐  │                      │          │
│  │  │ 同节点路径   │  │ 跨节点路径   │  │                      │          │
│  │  │             │  │             │  │                      │          │
│  │  │ mTLS 加密   │  │ 直接转发    │  │                      │          │
│  │  │ (eBPF)      │  │ (明文)      │  │                      │          │
│  │  └──────┬──────┘  └──────┬──────┘  │                      │          │
│  │         │                │         │                      │          │
│  │         ▼                ▼         │                      │          │
│  │  ┌─────────────┐  ┌─────────────┐  │                      │          │
│  │  │ Pod B       │  │ WireGuard   │  │                      │          │
│  │  │ mTLS 解密   │  │ 加密        │════════════════════════│          │
│  │  └─────────────┘  └─────────────┘  │   加密隧道           │          │
│  │                                    │                      │          │
│  └────────────────────────────────────┘                      │          │
│                                        │                      │          │
│                                        └──────────────────────┼──────────┤
│                                                               │          │
│                                        ┌──────────────────────┘          │
│                                        ▼                                 │
│                                 ┌─────────────┐                         │
│                                 │ WireGuard   │                         │
│                                 │ 解密        │                         │
│                                 └──────┬──────┘                         │
│                                        │                                 │
│                                        ▼                                 │
│                                 ┌─────────────┐                         │
│                                 │ Pod C       │                         │
│                                 │ (明文接收)  │                         │
│                                 └─────────────┘                         │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 2.2 加密策略矩阵

| 场景                 | 加密方式  | 加密层级    | 开销    |
| :------------------- | :-------- | :---------- | :------ |
| **同节点 Pod → Pod** | mTLS      | 应用层 (L7) | 5-8%    |
| **跨节点 Pod → Pod** | WireGuard | 网络层 (L3) | 3-5%    |
| **总平均开销**       | -         | -           | **~5%** |

### 2.3 覆盖范围

```
┌─────────────────────────────────────────────────────────────────┐
│                       加密覆盖范围                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ✅ 同节点 Pod 间通信                                           │
│     └─ mTLS 加密，应用层保护                                    │
│                                                                 │
│  ✅ 跨节点 Pod 间通信                                           │
│     └─ WireGuard 加密，网络层保护                               │
│                                                                 │
│  ✅ 覆盖所有协议                                                │
│     ├─ HTTP/HTTPS                                               │
│     ├─ gRPC                                                     │
│     ├─ TCP 自定义协议                                           │
│     └─ WireGuard 覆盖非 TLS 协议（如跨节点 MySQL）              │
│                                                                 │
│  ✅ 无双重加密                                                  │
│     └─ 每条路径只加密一次                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 配置实现

### 3.1 基础配置

```yaml
# cilium-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # 启用 WireGuard（跨节点加密）
  encryption: "wireguard"
  encryption-node-network: "true" # 节点间加密

  # 启用 L7 代理（mTLS 基础）
  enable-l7-proxy: "true"

  # 启用 mTLS 功能
  enable-mtls: "true"

  # 关键：配置 mTLS 行为
  # 选项：always, cross-node, never
  mtls-mode: "same-node" # 仅同节点使用 mTLS
```

### 3.2 同节点 mTLS 策略

```yaml
# same-node-mtls-policy.yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: same-node-mtls
  namespace: production
spec:
  # 应用于所有需要 mTLS 的服务
  endpointSelector:
    matchLabels:
      mtls-required: "true"

  # 入站规则：同节点流量要求 mTLS
  ingress:
    - fromEndpoints:
        # 匹配同节点的 Pod
        - matchExpressions:
            - key: k8s:io.cilium.k8s.node-name
              operator: In
              # 使用 K8s downward API 注入节点名
              values: ["${NODE_NAME}"]
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
          # 强制 TLS 终止
          terminatingTLS:
            secret:
              name: "${SERVICE_NAME}-tls"
              namespace: production
            # 验证客户端证书
            client:
              spiffe: true

  # 出站规则：同节点流量使用 mTLS
  egress:
    - toEndpoints:
        # 同节点的目标服务
        - matchExpressions:
            - key: k8s:io.cilium.k8s.node-name
              operator: In
              values: ["${NODE_NAME}"]
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
          # 发起 TLS 连接
          originatingTLS:
            secret:
              name: client-tls
              namespace: production
            server:
              # 验证服务端证书
              names:
                - "${TARGET_SERVICE}.production.svc.cluster.local"
```

### 3.3 跨节点 WireGuard 策略

```yaml
# cross-node-wireguard.yaml
# 跨节点流量自动由 WireGuard 保护
# 无需额外策略配置

# 验证 WireGuard 状态
# kubectl exec -n kube-system cilium-xxx -- cilium-dbg encrypt status

---
# 可选：标记跨节点服务
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: cross-node-allow
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: backend

  ingress:
    # 允许跨节点来源（WireGuard 已加密）
    - fromEndpoints:
        - matchExpressions:
            - key: k8s:io.cilium.k8s.node-name
              operator: NotIn
              values: ["${NODE_NAME}"]
      # 无需 TLS 要求，WireGuard 已保护
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
```

### 3.4 完整部署示例

```yaml
# deployment-with-hybrid-encryption.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: frontend
      mtls-required: "true" # 标记需要 mTLS
  template:
    metadata:
      labels:
        app: frontend
        mtls-required: "true"
      annotations:
        # 注入节点名（用于策略匹配）
        scheduling.node.kubernetes.io/affinity: |
          {"nodeAffinity": {"requiredDuringSchedulingIgnoredDuringExecution":
            {"nodeSelectorTerms": [{"matchExpressions":
              [{"key": "kubernetes.io/hostname", "operator": "In", "values": ["${NODE_NAME}"]}]}
            ]}}
    spec:
      containers:
        - name: frontend
          image: frontend:latest
          ports:
            - containerPort: 443
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: tls
              mountPath: /etc/tls
      volumes:
        - name: tls
          secret:
            secretName: frontend-tls
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backend
  namespace: production
spec:
  replicas: 3
  selector:
    matchLabels:
      app: backend
      mtls-required: "true"
  template:
    metadata:
      labels:
        app: backend
        mtls-required: "true"
    spec:
      containers:
        - name: backend
          image: backend:latest
          ports:
            - containerPort: 8080
```

---

## 4. 证书管理

### 4.1 使用 cert-manager 自动签发

```yaml
# cert-manager-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: cilium-mtls-ca
spec:
  ca:
    secretName: cilium-root-ca
---
# 服务证书
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: frontend-tls
  namespace: production
spec:
  secretName: frontend-tls
  duration: 24h
  renewBefore: 1h
  issuerRef:
    name: cilium-mtls-ca
    kind: ClusterIssuer
  dnsNames:
    - frontend.production.svc.cluster.local
    - frontend
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: backend-tls
  namespace: production
spec:
  secretName: backend-tls
  duration: 24h
  renewBefore: 1h
  issuerRef:
    name: cilium-mtls-ca
    kind: ClusterIssuer
  dnsNames:
    - backend.production.svc.cluster.local
    - backend
  usages:
    - digital signature
    - key encipherment
    - server auth
    - client auth
```

### 4.2 SPIFFE 集成（推荐）

```yaml
# Cilium 内置 SPIFFE 支持
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-config
  namespace: kube-system
data:
  # 启用 SPIFFE
  enable-spiffe: "true"

  # SPIFFE信任域
  spiffe-trust-domain: "cluster.local"

  # 自动签发 SVID
  spiffe-auto-rotate: "true"
```

---

## 5. 流量路径详解

### 5.1 同节点通信

```
同节点 Pod A → Pod B（mTLS 保护）：

Step 1: 应用发起请求
┌─────────────────────────────────────────────────────────────┐
│ App A (Pod frontend-xxx)                                    │
│ socket.connect(10.244.0.5:443)  // Pod B 的 IP              │
│ socket.send("GET /api/users")                               │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 2: eBPF 拦截并判断
┌─────────────────────────────────────────────────────────────┐
│ Cilium eBPF (tc-egress)                                     │
│                                                             │
│ 1. 解析目标 IP: 10.244.0.5                                  │
│ 2. 查表: 10.244.0.5 → 本节点 (Node A)                       │
│ 3. 策略检查: mtls-required = true                           │
│ 4. 动作: 应用 mTLS 加密                                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 3: mTLS 加密
┌─────────────────────────────────────────────────────────────┐
│ eBPF TLS 层                                                 │
│                                                             │
│ 1. 获取证书: frontend-tls                                   │
│ 2. TLS 握手: ClientHello → ServerHello                     │
│ 3. 加密数据: "GET /api/users" → [加密密文]                  │
│ 4. TLS Record: Type(0x17) | Length | Encrypted Data        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 4: 转发到目标 Pod
┌─────────────────────────────────────────────────────────────┐
│ Cilium eBPF (tc-ingress on Pod B veth)                      │
│                                                             │
│ 1. 接收加密流量                                             │
│ 2. mTLS 解密: [加密密文] → "GET /api/users"                 │
│ 3. 转发到 App B                                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ App B (Pod backend-xxx)                                     │
│ socket.recv() → "GET /api/users"                            │
│ (收到明文数据)                                              │
└─────────────────────────────────────────────────────────────┘

开销分析：
├─ mTLS 加密: ~1-2ms
├─ mTLS 解密: ~1-2ms
└─ 总延迟: ~2-4ms
```

### 5.2 跨节点通信

```
跨节点 Pod A (Node A) → Pod C (Node B)（WireGuard 保护）：

Step 1: 应用发起请求
┌─────────────────────────────────────────────────────────────┐
│ App A (Node A, Pod frontend-xxx)                            │
│ socket.connect(10.244.1.8:8080)  // Pod C 的 IP             │
│ socket.send("GET /api/data")                                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 2: eBPF 拦截并判断
┌─────────────────────────────────────────────────────────────┐
│ Cilium eBPF (tc-egress on Node A)                           │
│                                                             │
│ 1. 解析目标 IP: 10.244.1.8                                  │
│ 2. 查表: 10.244.1.8 → Node B (10.0.1.2)                    │
│ 3. 判断: 跨节点流量                                         │
│ 4. 策略: 跨节点使用 WireGuard，不应用 mTLS                  │
│ 5. 动作: 重定向到 cilium_wg0                                │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 3: WireGuard 加密
┌─────────────────────────────────────────────────────────────┐
│ WireGuard (cilium_wg0 on Node A)                            │
│                                                             │
│ 1. 查找 Peer: 10.244.1.8 → Node B (10.0.1.2)               │
│ 2. 加密: ChaCha20-Poly1305                                  │
│ 3. 封装:                                                    │
│    ┌─────────────────────────────────────────────┐          │
│    │ 外层 IP | UDP | WG Header | 加密的原始包    │          │
│    │ 10.0.0.1 → 10.0.1.2 | 51871                │          │
│    └─────────────────────────────────────────────┘          │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 4: 网络传输
┌─────────────────────────────────────────────────────────────┐
│ 物理网络                                                     │
│ Node A (10.0.0.1) ════════════ Node B (10.0.1.2)           │
│ UDP 51871 端口，加密流量                                     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 5: WireGuard 解密
┌─────────────────────────────────────────────────────────────┐
│ WireGuard (cilium_wg0 on Node B)                            │
│                                                             │
│ 1. 验证: Poly1305 MAC                                       │
│ 2. 解密: ChaCha20                                           │
│ 3. 输出: 原始 IP 包 (10.244.0.5 → 10.244.1.8)              │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
Step 6: 转发到目标 Pod
┌─────────────────────────────────────────────────────────────┐
│ Cilium eBPF (tc-ingress on Node B)                          │
│                                                             │
│ 1. 接收解密后的明文                                         │
│ 2. 查表: 10.244.1.8 → Pod C (veth lxc-yyy)                 │
│ 3. 转发到 Pod C                                             │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ App C (Node B, Pod backend-zzz)                             │
│ socket.recv() → "GET /api/data"                             │
│ (收到明文数据，网络层已被 WireGuard 保护)                   │
└─────────────────────────────────────────────────────────────┘

开销分析：
├─ WireGuard 加密: ~0.3-0.5ms
├─ 网络传输: 取决于网络
├─ WireGuard 解密: ~0.3-0.5ms
└─ 总延迟: ~0.6-1ms + 网络延迟
```

---

## 6. 性能对比

### 6.1 开销对比

```
┌─────────────────────────────────────────────────────────────────┐
│                      CPU 开销对比                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  无加密          ██████████████████████████████████████  100%   │
│                                                                 │
│  仅 WireGuard    ████████████████████████████████████    95-97%  │
│                  (-3~5%)                                       │
│                                                                 │
│  仅 mTLS         ██████████████████████████████        92-95%   │
│                  (-5~8%)                                       │
│                                                                 │
│  全双开          ████████████████████████            85-90%     │
│  (WG + mTLS)     (-10~15%)                                    │
│                                                                 │
│  混合策略        ████████████████████████████████    93-97%     │
│  (本方案)        (-3~7%)  ← 最优                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 延迟对比

| 场景       | 无加密 | 仅 WG   | 仅 mTLS | 全双开  | **混合策略** |
| :--------- | :----- | :------ | :------ | :------ | :----------- |
| **同节点** | 1ms    | 1ms     | 2-5ms   | 3-6ms   | **2-5ms**    |
| **跨节点** | 5ms    | 5.5-6ms | 8-12ms  | 10-15ms | **5.5-6ms**  |

### 6.3 详细开销分解

```
┌─────────────────────────────────────────────────────────────────┐
│                      开销分解                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  方案一：全双开（WireGuard + mTLS）                            │
│  ├─ 同节点流量：mTLS 5-8%                                      │
│  ├─ 跨节点流量：WireGuard 3-5% + mTLS 5-8% = 8-13%            │
│  └─ 平均开销：~10%                                             │
│                                                                 │
│  方案二：混合策略                                               │
│  ├─ 同节点流量：mTLS 5-8%                                      │
│  ├─ 跨节点流量：WireGuard 3-5%（无 mTLS）                      │
│  └─ 平均开销：~5%（节省 50%）                                  │
│                                                                 │
│  假设场景：                                                     │
│  ├─ 50% 同节点流量                                             │
│  └─ 50% 跨节点流量                                             │
│                                                                 │
│  全双开：50% × 7% + 50% × 10% = 8.5%                           │
│  混合策略：50% × 7% + 50% × 4% = 5.5%                          │
│  节省：35%                                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 安全分析

### 7.1 安全覆盖

```
┌─────────────────────────────────────────────────────────────────┐
│                      安全覆盖矩阵                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  威胁场景                      │ 全双开 │ 混合策略 │ 仅 WG │ 仅 mTLS │
│  ─────────────────────────────┼────────┼──────────┼───────┼─────────│
│  同节点流量被窃听              │   ✅   │    ✅    │  ❌   │   ✅    │
│  跨节点流量被窃听              │   ✅   │    ✅    │  ✅   │   ✅    │
│  网络元数据泄露（IP/端口）     │   ✅   │    ⚠️   │  ✅   │   ❌    │
│  非TLS协议被窃听               │   ✅   │    ✅    │  ✅   │   ❌    │
│  流量分析攻击                  │   ✅   │    ✅    │  ✅   │   ⚠️    │
│  中间人攻击                    │   ✅   │    ✅    │  ✅   │   ✅    │
│                                                                 │
│  ✅ = 完全防护                                                  │
│  ⚠️ = 部分防护                                                  │
│  ❌ = 无防护                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 混合策略的安全特点

```
┌─────────────────────────────────────────────────────────────────┐
│                    混合策略安全分析                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ✅ 所有 Pod 间通信都被加密                                     │
│     ├─ 同节点：mTLS（应用层）                                  │
│     └─ 跨节点：WireGuard（网络层）                             │
│                                                                 │
│  ✅ 覆盖所有协议类型                                           │
│     ├─ HTTPS：应用层 TLS                                       │
│     ├─ HTTP：跨节点由 WG 保护                                  │
│     ├─ MySQL/Redis：跨节点由 WG 保护                           │
│     └─ 自定义 TCP：跨节点由 WG 保护                            │
│                                                                 │
│  ⚠️ 跨节点流量网络层元数据在同节点侧可见                       │
│     ├─ 同节点内：可以看到 TLS 加密的元数据                     │
│     └─ 但数据本身已加密                                        │
│                                                                 │
│  ✅ 零信任兼容                                                 │
│     └─ 所有通信都需要验证和加密                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. 故障排查

### 8.1 验证配置

```bash
# 1. 检查 WireGuard 状态
kubectl exec -n kube-system cilium-xxx -- cilium-dbg encrypt status

# 期望输出：
# Encryption: WireGuard
# Node to Node encryption: Enabled

# 2. 检查 WireGuard 连接
kubectl exec -n kube-system cilium-xxx -- wg show cilium_wg0

# 期望输出：
# interface: cilium_wg0
#   public key: ...
#   listening port: 51871
#
# peer: ...
#   endpoint: 10.0.1.2:51871
#   allowed ips: 10.244.1.0/24

# 3. 检查 mTLS 策略
kubectl get ciliumnetworkpolicy -n production

# 4. 检查证书
kubectl get certificates -n production
kubectl describe certificate frontend-tls -n production
```

### 8.2 常见问题

```
问题 1: 同节点 mTLS 不生效
─────────────────────────────────
症状：同节点流量明文传输

排查：
1. 检查 Pod 标签是否包含 mtls-required: "true"
2. 检查 CiliumNetworkPolicy 是否正确匹配
3. 检查证书是否存在

解决：
kubectl label pod frontend-xxx mtls-required=true


问题 2: 跨节点流量没有走 WireGuard
─────────────────────────────────
症状：跨节点流量明文

排查：
1. 检查 WireGuard 是否启用
2. 检查 cilium_wg0 设备状态
3. 检查节点间 UDP 51871 是否可达

解决：
# 检查防火墙
iptables -L -n | grep 51871

# 测试节点连通性
nc -zuv <peer-node-ip> 51871


问题 3: 证书过期
─────────────────────────────────
症状：mTLS 握手失败

排查：
kubectl get certificate frontend-tls -n production -o yaml

解决：
# 如果使用 cert-manager，检查自动轮换
kubectl describe certificate frontend-tls -n production
```

### 8.3 调试命令

```bash
# 抓包验证加密

# 1. 同节点流量（应该看到 TLS）
kubectl exec -n production frontend-xxx -- tcpdump -i eth0 port 443 -nn

# 2. 跨节点流量（应该看到 UDP 51871）
kubectl exec -n kube-system cilium-xxx -- tcpdump -i eth0 udp port 51871 -nn

# 3. 查看 eBPF 状态
kubectl exec -n kube-system cilium-xxx -- cilium-dbg bpf policy get

# 4. 查看身份映射
kubectl exec -n kube-system cilium-xxx -- cilium-dbg bpf ipcache list
```

---

## 9. 最佳实践

### 9.1 部署建议

```
┌─────────────────────────────────────────────────────────────────┐
│                      部署最佳实践                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 证书管理                                                    │
│     ├─ 使用 cert-manager 自动管理                              │
│     ├─ 证书有效期 24-72 小时                                   │
│     ├─ 提前 1-2 小时轮换                                       │
│     └─ 使用 SPIFFE 简化身份管理                                │
│                                                                 │
│  2. 策略配置                                                    │
│     ├─ 使用 K8s downward API 注入节点名                        │
│     ├─ 统一标签规范（mtls-required）                           │
│     └─ 使用 ClusterwidePolicy 简化管理                         │
│                                                                 │
│  3. 监控告警                                                    │
│     ├─ 监控 WireGuard 连接状态                                 │
│     ├─ 监控证书过期时间                                        │
│     ├─ 监控加密开销                                            │
│     └─ 监控 TLS 握手失败率                                     │
│                                                                 │
│  4. 故障恢复                                                    │
│     ├─ 准备降级方案（仅 WireGuard）                            │
│     ├─ 证书快速轮换脚本                                        │
│     └─ 节点驱逐策略                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 9.2 监控指标

```yaml
# Prometheus 监控规则
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-encryption
  namespace: monitoring
spec:
  groups:
    - name: cilium-encryption
      rules:
        # WireGuard 连接状态
        - alert: CiliumWireGuardPeerDown
          expr: cilium_wireguard_peer_last_handshake_seconds > 180
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "WireGuard peer handshake overdue"

        # 证书即将过期
        - alert: CertificateExpiringSoon
          expr: certmanager_certificate_expiration_timestamp_seconds - time() < 3600
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Certificate expiring in 1 hour"

        # 加密开销过高
        - alert: HighEncryptionOverhead
          expr: rate(cilium_encrypt_cpu_seconds_total[5m]) > 0.15
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Encryption CPU overhead exceeds 15%"
```

---

## 10. 总结

### 10.1 方案优势

```
┌─────────────────────────────────────────────────────────────────┐
│                      混合策略优势                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ✅ 安全覆盖完整                                                │
│     └─ 所有 Pod 间通信都加密，无盲区                           │
│                                                                 │
│  ✅ 性能开销最优                                                │
│     └─ 避免双重加密，节省 35-50% 开销                          │
│                                                                 │
│  ✅ 零信任兼容                                                  │
│     └─ 满足零信任架构要求                                      │
│                                                                 │
│  ✅ 灵活可扩展                                                  │
│     └─ 可根据服务敏感性调整策略                                │
│                                                                 │
│  ✅ 覆盖所有协议                                                │
│     └─ WireGuard 覆盖非 TLS 协议                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 10.2 适用场景

| 场景                    | 推荐方案               |
| :---------------------- | :--------------------- |
| **高性能 + 零信任**     | **混合策略（本方案）** |
| **高安全要求（金融）**  | 全双开                 |
| **性能敏感 + 内网可信** | 仅 WireGuard           |
| **简单场景 + 已有 TLS** | 仅 mTLS                |

### 10.3 一句话总结

**混合加密策略（跨节点 WireGuard + 同节点 mTLS）是性能与安全的最佳平衡点，避免双重加密冗余，开销降至 ~5%，同时保证所有流量加密无盲区。**

---

## 外部参考

- [Cilium Encryption Documentation](https://docs.cilium.io/en/stable/security/network/encryption/)
- [Cilium mTLS with eBPF](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)
- [WireGuard Protocol](https://www.wireguard.com/)
- [SPIFFE Specification](https://spiffe.io/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
