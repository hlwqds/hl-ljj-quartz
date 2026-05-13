---
title: "VPN 技术深度探索 (三十八)：SPIFFE 身份体系"
date: 2026-04-13
tags: [vpn, series, spiffe, identity, workload, svidaemon, service-mesh]
description: "SPIFFE 身份体系深度解析——SPIFFE ID 格式、SVID 工作负载身份证书、Workload API、SPIRE 实现与服务网格身份联动"
---

> [!info] VPN 技术深度探索系列 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-vpn-deep-dive-ch37-ztna|第三十七章：零信任网络 ZTNA]]
> 2. **第三十八章：SPIFFE 身份体系**
> 3. [[2026-04-13-vpn-deep-dive-ch39-mtls|第三十九章：mTLS 双向认证]]

---

## 1. 概述：为什么需要工作负载身份

在零信任架构中，**身份**是访问控制的核心。不只是用户需要身份，工作负载（Workload，即运行的服务、容器、VM）也需要身份来相互认证。

```
工作负载身份问题：

┌─────────────────────────────────────────────────────────────────┐
│                    传统 vs SPIFFE 身份                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  传统模式：                                                     │
│  ├─ 服务使用 IP 地址标识                                        │
│  ├─ 依赖网络层防火墙隔离                                        │
│  ├─ 证书手动管理，生命周期长                                     │
│  └─ 问题：IP 会变，证书难管理                                   │
│                                                                 │
│  SPIFFE 模式：                                                  │
│  ├─ 服务使用 URI 格式的身份标识（SPIFFE ID）                   │
│  ├─ 自动化证书颁发与轮换                                        │
│  ├─  workload API 动态获取凭证                                 │
│  └─ 优势：身份与网络位置解耦                                    │
│                                                                 │
│  SPIFFE 适用场景：                                              │
│  ├─ Kubernetes 集群内服务间认证                                 │
│  ├─ 微服务之间的 mTLS                                          │
│  ├─ 跨集群服务通信                                              │
│  └─ 云原生安全架构                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 1.1 SPIFFE 项目简介

SPIFFE（Secure Production Identity Framework For Everyone）是 CNCF 孵化项目，定义了一套标准化的工作负载身份框架：

```
SPIFFE 项目：

┌─────────────────────────────────────────────────────────────────┐
│                    SPIFFE 项目概览                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  官方定义：                                                     │
│  「SPIFFE 是一套标准，用于为现代生产环境中的工作负载提供                                  │
│   统一的身份上下文。」                                           │
│                                                                 │
│  核心组件：                                                      │
│  ├─ SPIFFE ID：工作负载的统一身份标识                           │
│  ├─ SVID：SPIFFE Verifiable Identity Document                  │
│  ├─ Workload API：工作负载获取身份的 API                        │
│  └─ SPIRE：SPIFFE Runtime Environment（参考实现）              │
│                                                                 │
│  标准化内容：                                                    │
│  ├─ ID 格式规范（RFC Draft）                                   │
│  ├─ SVID 格式（X.509 / JWT）                                   │
│  └─ API 规范（gRPC）                                            │
│                                                                 │
│  生态集成：                                                      │
│  ├─ Envoy / Istio                                              │
│  ├─ Kubernetes                                                 │
│  ├─ AWS / GCP / Azure Workload Identity                       │
│  └─ Vault                                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. SPIFFE ID

### 2.1 SPIFFE ID 格式

SPIFFE ID 是一个 URI，遵循特定格式：

```
SPIFFE ID 格式：

┌─────────────────────────────────────────────────────────────────┐
│                    SPIFFE ID 结构                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  完整格式：                                                      │
│                                                                 │
│  spiffe://trust-domain/path/spath/...                          │
│  ├───────────┬───────────────┤                                  │
│  │           │               │                                  │
│  │    │      │               └── 可选的路径组件                   │
│  │    │      │                                                │
│  │    │      └── 信任域（Trust Domain）                         │
│  │    │                                                        │
│  │    └── 协议前缀                                             │
│  │                                                           │
│  │   必需部分                                                    │
│                                                                 │
│  示例：                                                         │
│  ├─ spiffe://example.com/ns/foo/sa/bar                        │
│  ├─ spiffe://production.internal/k8s-user/jane                │
│  └─ spiffe://cloud-aws.com/workload/frontend                   │
│                                                                 │
│  规则：                                                         │
│  ├─ 必需以 spiffe:// 开头                                       │
│  ├─ 必须包含 trust-domain                                        │
│  ├─ trust-domain 必须是 DNS 名称（建议）                        │
│  ├─ path 可包含字母、数字、/、.、-、_                            │
│  └─ 区分大小写                                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Trust Domain

Trust Domain（信任域）是 SPIFFE 的核心概念，代表共享信任根的安全边界：

```
Trust Domain 定义：

┌─────────────────────────────────────────────────────────────────┐
│                    Trust Domain 概念                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  定义：                                                         │
│  ├─ 共享信任根的一组工作负载                                     │
│  ├─ 通常对应一个组织或服务集合                                    │
│  └─ 类似 PKI 的 CA 域                                            │
│                                                                 │
│  示例划分：                                                     │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                                                          │  │
│  │  Trust Domain: example.com                              │  │
│  │                                                          │  │
│  │  ├─ Production (生产环境)                              │  │
│  │  │   ├─ spiffe://example.com/prod/api                  │  │
│  │  │   └─ spiffe://example.com/prod/db                  │  │
│  │  │                                                       │  │
│  │  ├─ Staging (预发环境)                                  │  │
│  │  │   ├─ spiffe://example.com/staging/api              │  │
│  │  │   └─ spiffe://example.com/staging/db              │  │
│  │  │                                                       │  │
│  │  └─ Dev (开发环境)                                      │  │
│  │      └─ spiffe://example.com/dev/api                  │  │
│  │                                                          │  │
│  │  注意：生产环境的服务不应该信任开发环境的 SVID            │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  命名建议：                                                      │
│  ├─ 使用 DNS 域名格式                                           │
│  ├─ 与组织边界对应                                              │
│  ├─ 跨组织需要联邦信任                                          │
│  └─ 避免使用公共域名（除非是多租户 SaaS）                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. SVID 工作负载身份文档

### 3.1 SVID 概述

SVID（SPIFFE Verifiable Identity Document）是工作负载的身份凭证：

```
SVID 类型：

┌─────────────────────────────────────────────────────────────────┐
│                    SVID 两种格式                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. X.509 SVID：                                               │
│  ├─ 基于 PKI 的标准 X.509 证书                                  │
│  ├─ SAN（Subject Alternative Name）包含 SPIFFE ID             │
│  ├─ 适合服务网格（mTLS）                                        │
│  └─ 推荐用于服务间通信                                          │
│                                                                 │
│  2. JWT SVID：                                                 │
│  ├─ 基于 JWT 的令牌                                            │
│  ├─ claims 包含 SPIFFE ID                                       │
│  ├─ 适合跨域认证（如 API 网关）                                  │
│  └─ 推荐用于联邦场景                                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │              X.509 SVID 结构                             │  │
│  │                                                          │  │
│  │  Certificate:                                           │  │
│  │    Subject: CN=workload                                 │  │
│  │    Subject Alternative Name:                            │  │
│  │      URI: spiffe://example.com/ns/foo/sa/bar          │  │
│  │    Issuer: CA of example.com                           │  │
│  │    Validity: 24h (短期证书)                             │  │
│  │                                                          │  │
│  │  注意：证书有效期通常很短（几小时）                      │  │
│  │  → 自动轮换，无需人工干预                               │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 X.509 SVID 详解

```
X.509 SVID 字段：

┌─────────────────────────────────────────────────────────────────┐
│                    X.509 SVID 证书字段                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  必需字段：                                                      │
│  ├─ Version: v3 (3)                                            │
│  ├─ Serial Number: 随机数                                      │
│  ├─ Issuer: 签发 CA 的 DN                                       │
│  ├─ Validity: 短期（建议 1-24 小时）                           │
│  ├─ Subject: CN = <workload name>                              │
│  └─ Subject Alternative Name (SAN):                            │
│       └─ URI: spiffe://<trust-domain>/<path>                  │
│                                                                 │
│  可选字段：                                                      │
│  ├─ Basic Constraints: CA:FALSE                                 │
│  ├─ Key Usage: Digital Signature                               │
│  └─ Extended Key Usage: Server Auth / Client Auth             │
│                                                                 │
│  对比传统证书：                                                  │
│  ┌────────────────────┬──────────────────┬──────────────────┐ │
│  │       字段          │    传统证书      │   X.509 SVID    │ │
│  ├────────────────────┼──────────────────┼──────────────────┤ │
│  │  身份标识          │  CN/DNS          │  SPIFFE ID (SAN) │ │
│  │  有效期            │  1-3年           │  几小时          │ │
│  │  颁发方式          │  手动/半自动     │  自动 API        │ │
│  │  信任锚点          │  公共 CA 或私有  │  Trust Domain CA │ │
│  └────────────────────┴──────────────────┴──────────────────┘ │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 JWT SVID 详解

```
JWT SVID 结构：

┌─────────────────────────────────────────────────────────────────┐
│                    JWT SVID 结构                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Header:                                                       │
│  {                                                             │
│    "alg": "RS256",                                             │
│    "typ": "JWT",                                               │
│    "kid": "key-id-1"                                           │
│  }                                                             │
│                                                                 │
│  Payload (Claims):                                             │
│  {                                                             │
│    "iss": "spiffe://example.com",        # Trust Domain       │
│    "sub": "spiffe://example.com/workload", # SPIFFE ID        │
│    "aud": "spiffe://example.com/audience", # 受众（可选）      │
│    "exp": 1700000000,                     # 过期时间            │
│    "iat": 1699990000,                     # 签发时间            │
│    " SPIFFE-ID": "spiffe://example.com/workload"              │
│  }                                                             │
│                                                                 │
│  Signature:                                                    │
│  └─ 由 Trust Domain CA 签发                                     │
│                                                                 │
│  使用场景：                                                     │
│  ├─ API 网关 认证                                              │
│  ├─ 跨 Trust Domain 访问                                      │
│  ├─ 外部系统集成                                               │
│  └─ 短期令牌（相比证书更轻量）                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. Workload API

### 4.1 API 概述

Workload API 是工作负载获取身份的接口：

```
Workload API：

┌─────────────────────────────────────────────────────────────────┐
│                    Workload API 定义                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  设计原则：                                                     │
│  ├─ 简单：最小化依赖                                            │
│  ├─ 安全：UDS（Unix Domain Socket），避免网络暴露              │
│  └─ 动态：支持证书轮换                                          │
│                                                                 │
│  通信方式：                                                     │
│  ├─ gRPC over UDS                                              │
│  ├─ 路径：/run/spire/sockets/agent.sock                        │
│  └─ 避免暴露在网络上                                            │
│                                                                 │
│  主要接口：                                                     │
│                                                                 │
│  1. FetchX509SVID：                                            │
│     → 获取 X.509 SVID 及其 CA 链                               │
│                                                                 │
│  2. FetchX509Bundles：                                         │
│     → 获取所有 Trust Domain 的 CA 证书                          │
│     → 用于验证其他服务                                          │
│                                                                 │
│  3. FetchJWTsvid：                                            │
│     → 获取 JWT SVID                                             │
│     → 指定 audience                                             │
│                                                                 │
│  4. FetchJWT Bundles：                                         │
│     → 获取 JWT 签名密钥                                         │
│                                                                 │
│  5. SubscribeToChanges：                                       │
│     → 订阅证书变化通知                                           │
│     → 实现自动重载                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 API 使用流程

```
Workload API 使用流程：

┌─────────────────────────────────────────────────────────────────┐
│                    SVID 获取流程                                 │
├─────────────────────────────────────────────────────────────────�─┤
│                                                                 │
│  Workload                               SPIRE Agent              │
│    │                                        │                   │
│    │  1. 调用 FetchX509SVID()               │                   │
│    │ ──────────────────────────────────────>                    │
│    │                                        │                   │
│    │     验证 workload 的身份（通过 K8s SAT、                     │
│    │     AWS IID、UUID 等方式）                                 │
│    │                                        │                   │
│    │  2. 返回 SVID + CA Bundle            │                   │
│    │ <──────────────────────────────────────                    │
│    │                                        │                   │
│    │  3. 使用 SVID 进行 mTLS 通信         │                   │
│    │ ────────────────────────────────────────> Service B       │
│    │                                        │                   │
│    │                                        │                   │
│    │  4. Service B 验证 SVID              │                   │
│    │     （使用 CA Bundle 中的根证书）    │                   │
│    │                                        │                   │
│                                                                 │
│  后续：证书过期前自动续期                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. SPIRE 架构与实现

### 5.1 SPIRE 组件

SPIRE 是 SPIFFE 的参考实现：

```
SPIRE 架构：

┌─────────────────────────────────────────────────────────────────┐
│                    SPIRE 组件                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                      SPIRE Server                        │  │
│  │                                                           │  │
│  │  职责：                                                   │  │
│  │  ├─ 管理注册条目（Registration Entries）                 │  │
│  │  ├─ 签发 SVID                                            │  │
│  │  ├─ 管理 Trust Bundle                                    │  │
│  │  └─ 与 Node Attestor 交互                                │  │
│  │                                                           │  │
│  │  数据存储：                                               │  │
│  │  ├─ PostgreSQL / MySQL / SQLite                          │  │
│  │  └─ 插件化支持                                            │  │
│  │                                                           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           │                                      │
│                           │ gRPC (mTLS)                          │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                      SPIRE Agent                          │  │
│  │                                                           │  │
│  │  职责：                                                   │  │
│  │  ├─ 运行在每个节点（K8s Node / VM）                      │  │
│  │  ├─ 提供 Workload API (UDS)                             │  │
│  │  ├─ 节点证明（Node Attestation）                         │  │
│  │  └─ 缓存 SVID                                             │  │
│  │                                                           │  │
│  │  部署：                                                   │  │
│  │  ├─ DaemonSet (Kubernetes)                               │  │
│  │  ├─ Systemd service (VM)                                │  │
│  │  └─ 每节点一个                                            │  │
│  │                                                           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           │                                      │
│                           │ UDS                                  │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                      Workload                            │  │
│  │  (K8s Pod / VM / Container)                             │  │
│  │                                                           │  │
│  │  使用 SDK 或 Sidecar 获取 SVID                           │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 节点证明（Node Attestation）

节点证明是 SPIRE 验证节点身份的过程：

```
节点证明机制：

┌─────────────────────────────────────────────────────────────────┐
│                    Node Attestation                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  流程：                                                         │
│  1. Agent 启动，向 Server 证明节点身份                           │
│  2. Server 验证通过后，Agent 注册                               │
│  3. Agent 开始提供 Workload API                                 │
│                                                                 │
│  支持的 Attestor 类型：                                          │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  平台类型           │  Attestor 插件                      │  │
│  ├────────────────────┼───────────────────────────────────┤  │
│  │  Kubernetes        │  K8s SAT (Service Account Token)  │  │
│  │  AWS               │  AWS IID (Instance Identity)       │  │
│  │  GCP               │  GCP IID                           │  │  │
│  │  Azure             │  Azure MSI                         │  │
│  │  Docker           │  Docker FID                       │  │
│  │  Generic          │  Unix (Host基底)                    │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  K8s 证明示例：                                                 │
│                                                                 │
│  Agent 获取 Service Account Token                              │
│  → 发送给 Server 进行验证                                        │
│  → Server 调用 K8s API 验证 Token                               │
│  → 验证 Pod 所属的 Namespace、Service Account                    │
│  → 颁发包含该身份的 SVID                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.3 注册条目（Registration Entry）

```
SPIRE Registration Entry：

┌─────────────────────────────────────────────────────────────────┐
│                    注册条目结构                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Entry 定义：                                                   │
│  {                                                             │
│    "entryID": "abc123",                                       │
│    "spiffeID": "spiffe://example.com/ns/default/sa/default",   │
│    "parentID": "spiffe://example.com/spire/agent/k8s/...",    │
│    "ttl": 3600,                                               │
│    " selectors": [                                             │
│      { "type": "k8s", "key": "ns", "value": "default" },       │
│      { "type": "k8s", "key": "sa", "value": "default" }        │
│    ]                                                           │
│  }                                                             │
│                                                                 │
│  Selector 匹配逻辑：                                            │
│  ├─ K8s: ns, sa, pod-label, pod-uid                           │
│  ├─ Docker: image-label, container-name                       │
│  ├─ Unix: uid, gid, user, group                               │
│  └─ AWS: instance-tag, role-name                              │
│                                                                 │
│  示例：                                                         │
│                                                                 │
│  所有 default namespace 的 Pod 都获得：                         │
│  spiffe://example.com/ns/default/sa/default                   │
│                                                                 │
│  带有 app=frontend label 的 Pod 获得：                         │
│  spiffe://example.com/app/frontend                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. SPIRE 部署

### 6.1 Kubernetes 部署

```
SPIRE Kubernetes 部署：

┌─────────────────────────────────────────────────────────────────┐
│                    SPIRE K8s 架构                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Namespace: spire                                               │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  SPIRE Server (Deployment)                              │  │
│  │  ├─ 1 replica (可多)                                    │  │
│  │  ├─ PVC for Data store                                   │  │
│  │  └─ Service: spire-server.spire.svc.cluster.local       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           │                                      │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  SPIRE Agent (DaemonSet)                                 │  │
│  │  ├─ 每节点一个 Pod                                       │  │
│  │  ├─ HostPath: /run/spire/sockets                         │  │
│  │  └─ HostPath: /var/lib/kubelet/pods                      │  │
│  └──────────────────────────────────────────────────────────┘  │
│                           │                                      │
│                           │ UDS                                  │
│                           ▼                                      │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │  Workload Pod (Application)                              │  │
│  │  ├─ Volume: spire-agent-socket                            │  │
│  │  ├─ env: SPIFFE_END_SOCKET_PATH                         │  │
│  │  └─ 使用 SPIFFE API 获取 SVID                            │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ConfigMap 示例：                                               │
│                                                                 │
│  apiVersion: v1                                                │
│  kind: ConfigMap                                               │
│  metadata:                                                     │
│    name: spire-agent                                           │
│    namespace: spire                                           │
│  data:                                                         │
│    agent.conf: |                                               │
│      agent:                                                   │
│        trust_domain: example.com                              │
│        server_address: spire-server.spire.svc.cluster.local │
│        socket_path: /run/spire/sockets/agent.sock            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 快速部署命令

```
SPIRE 快速部署（K8s）：

┌─────────────────────────────────────────────────────────────────┐
│                    SPIRE 部署命令                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 添加 Helm Repo：                                           │
│                                                                 │
│  helm repo add spiffe https://charts.spiffe.io                 │
│  helm repo update                                              │
│                                                                 │
│  2. 部署 SPIRE Server：                                        │
│                                                                 │
│  helm install spire-server spiffe/spire-server \             │
│    --namespace spire \                                         │
│    --create-namespace \                                        │
│    --set spire-server.dataStorage.size=1Gi                    │
│                                                                 │
│  3. 部署 SPIRE Agent (每个节点)：                              │
│                                                                 │
│  helm install spire-agent spiffe/spire-agent \               │
│    --namespace spire \                                         │
│    --set spire-agent.socketPath=/run/spire/sockets/agent.sock│
│                                                                 │
│  4. 创建 Registration Entry：                                  │
│                                                                 │
│  kubectl exec -n spire spire-server-0 -- \                    │
│    /opt/spire/bin/spire-server entry create \                 │
│    --spiffeID spiffe://example.com/ns/default/sa/default     │
│    --parentID spiffe://example.com/spire/agent/k8s_psat/...   │
│    --selector k8s:ns:default                                  │
│    --selector k8s:sa:default                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. SPIFFE 与服务网格

### 7.1 Istio 集成

Istio 使用 SPIFFE 作为工作负载身份的基础：

```
Istio + SPIFFE：

┌─────────────────────────────────────────────────────────────────┐
│                    Istio SPIFFE 实现                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Istio 身份格式：                                               │
│  spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>  │
│                                                                 │
│  示例：                                                         │
│  spiffe://cluster.local/ns/default/sa/bookinfo-frontend        │
│                                                                 │
│  Istio 组件对应：                                               │
│  ├─ Citadel (= SPIRE Server)：颁发管理证书                      │
│  ├─ Agent (= SPIRE Agent)：每个 Node 运行，提供 API             │
│  └─ Workload API = Envoy SDS API                               │
│                                                                 │
│  证书轮换：                                                     │
│  ├─ 默认 24 小时轮换                                           │
│  ├─ 可配置更短（如 1 小时）                                    │
│  └─ 自动，无需中断连接                                          │
│                                                                 │
│  Envoy 获取证书流程：                                           │
│  1. Envoy 通过 SDS API 请求证书                                 │
│  2. Istio Agent 调用 Workload API 获取 SVID                    │
│  3. Istio Agent 返回证书给 Envoy                               │
│  4. Envoy 使用证书进行 mTLS                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 与应用层集成

````
SPIFFE 应用集成方式：

┌─────────────────────────────────────────────────────────────────┐
│                    应用集成方式                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  方式 1：SPIFFE SDK（推荐）                                     │
│  ├─ Go: github.com/spiffe/go-spiffe                          │
│  ├─ Java: github.com/spiffe/java-spiffe                      │
│  ├─ Python: github.com/spiffe/python-spiffe                  │
│  └─ 直接调用 Workload API，自动管理证书                        │
│                                                                 │
│  方式 2：Envoy Sidecar 代理                                    │
│  ├─ 应用无需修改                                                │
│  ├─ Envoy 终止 mTLS                                            │
│  ├─ 应用通过 localhost 通信                                     │
│  └─ Istio/Linkerd 默认方式                                     │
│                                                                 │
│  方式 3：修改应用使用 TLS                                       │
│  ├─ 应用调用 Workload API 获取 SVID                            │
│  ├─ 应用直接使用 SVID 进行 TLS                                 │
│  └─ 侵入性较大，但性能更好                                      │
│                                                                 │
│  Go SDK 示例：                                                 │
│                                                                 │
│  ```                                                           │
│  // 创建 TLS Config                                             │
│  ctx := context.Background()                                    │
│  bundle, err := workloadapi.FetchX509Bundle(ctx)               │
│  source, err := workloadapi.GetX509Source(ctx)                 │
│                                                                 │
│  // 获取 SVID                                                   │
│  svid, err := source.GetX509SVID()                             │
│  ```                                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
````

---

## 8. SPIFFE 联邦

### 8.1 跨 Trust Domain 信任

当服务需要跨组织或跨云访问时，需要 SPIFFE 联邦：

```
SPIFFE 联邦：

┌─────────────────────────────────────────────────────────────────┐
│                    Trust Federation                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  场景：                                                         │
│  ├─ Organization A 的服务访问 Organization B 的 API            │
│  ├─ Multi-cloud：AWS 访问 GCP 服务                             │
│  └─ Merged M&A：合并前公司间通信                                │
│                                                                 │
│  机制：                                                         │
│  ├─ 每个 Trust Domain 维护自己的 CA                            │
│  ├─ 通过 Trust Bundle 交换建立信任                              │
│  └─ JWT SVID 用于跨域认证                                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                                                          │  │
│  │   Domain A                  Domain B                    │  │
│  │   example.com               partner.com                   │  │
│  │       │                         │                        │  │
│  │       │  交换 Trust Bundle      │                        │  │
│  │       ├ ─────────────────────── ┤                         │  │
│  │       │                         │                        │  │
│  │       ▼                         ▼                        │  │
│  │   Service A ────────────────> Service B                  │  │
│  │   (验证 B 的 JWT SVID)      (使用 JWT SVID 认证)          │  │
│  │                                                          │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                 │
│  配置：                                                         │
│  ├─ SPIRE Server 配置 Federation Trust Bundle                 │
│  ├─ 定期从对方获取 Trust Bundle                                │
│  └─ 验证 JWT 时使用对方的 JWKS                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 9. 总结

SPIFFE 提供了一套标准化的服务身份框架：

```
SPIFFE 核心要点总结：

┌─────────────────────────────────────────────────────────────────┐
│                    SPIFFE 关键要点                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  核心概念：                                                      │
│  ├─ SPIFFE ID：工作负载的统一身份标识（URI 格式）               │
│  ├─ SVID：可验证的身份凭证（X.509/JWT）                        │
│  ├─ Trust Domain：信任边界                                      │
│  └─ Workload API：自动获取身份的接口                           │
│                                                                 │
│  SVID 特性：                                                     │
│  ├─ 短期证书（小时级）                                          │
│  ├─ 自动轮换                                                    │
│  ├─ 自动下发（无需人工）                                        │
│  └─ X.509 适合 mTLS，JWT 适合 API 认证                         │
│                                                                 │
│  SPIRE 实现：                                                    │
│  ├─ Server：管理条目，签发证书                                  │
│  ├─ Agent：节点代理，提供 Workload API                         │
│  └─ 支持 K8s、AWS、GCP、Azure 等平台                           │
│                                                                 │
│  应用场景：                                                      │
│  ├─ 服务网格（Istio/Linkerd）                                   │
│  ├─ 微服务 mTLS                                                 │
│  ├─ 跨云/跨组织身份                                             │
│  └─ 零信任网络基础                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

> [!info] 下章预告
> [[2026-04-13-vpn-deep-dive-ch39-mtls|第三十九章：mTLS 双向认证]] — mTLS 流程、证书管理、Istio/Envoy 实现、自动化
