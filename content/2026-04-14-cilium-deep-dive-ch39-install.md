---
title: "Cilium 深度探索 (39)：生产级安装指南"
date: 2026-04-14
tags:
  - cilium
  - installation
  - helm
  - kubernetes
  - deployment
  - operations
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ... 38. [[2026-04-14-cilium-deep-dive-ch38-sockmap|第三十八章：Sockmap]] 39. **第三十九章：生产级安装指南** ← 40. [[2026-04-14-cilium-deep-dive-ch40-upgrade|第四十章：升级策略]] 41. [[2026-04-14-cilium-deep-dive-ch41-debug|第四十一章：故障诊断]] 42. [[2026-04-14-cilium-deep-dive-ch42-performance|第四十二章：性能调优]]

---

## 1. 安装概述

Cilium 的安装方式有多种，生产环境推荐使用 Helm 也可使用 `cilium install` 命令。本章详解 Helm 安装方式、配置选项、最佳实践，帮助你部署一个生产级的 Cilium 集群。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Cilium 安装方式对比                                │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   ┌─────────────────┐    ┌─────────────────┐    ┌───────────────┐  │
│   │   cilium CLI    │    │      Helm       │    │  Operator     │  │
│   │  (开发/测试)     │    │   (生产推荐)     │    │  (自动安装)    │  │
│   └────────┬────────┘    └────────┬────────┘    └───────┬───────┘  │
│            │                      │                    │          │
│            │    ┌──────────────────┴───────────────────┐          │
│            │    │                                      │          │
│            ▼    ▼                                      ▼          │
│     ┌───────────────┐                          ┌───────────────┐  │
│     │  quick-install│                          │  独立部署      │  │
│     │  (最小配置)    │                          │  (手动模式)    │  │
│     └───────────────┘                          └───────────────┘  │
│                                                                     │
│   推荐: Helm = 可版本化 + 可配置 + 可复现 + 生产级                    │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 前置要求

安装 Cilium 前，集群必须满足以下条件：

| 要求         | 最低版本 | 说明                                |
| :----------- | :------- | :---------------------------------- |
| Kubernetes   | 1.24+    | 生产环境推荐 1.27+                  |
| Linux Kernel | 4.19+    | 5.10+ 获得完整功能                  |
| eBPF         | 支持     | 检查 `/sys/kernel/debugsubsys/eBPF` |
| Helm         | 3.6+     | 用于 Chart 安装                     |
| kubectl      | 1.21+    | 与集群交互                          |

```
# 检查内核版本
uname -r
# 5.10.0-xxxx-generic

# 检查 eBPF 支持
ls /sys/kernel/debug/tracing/ebpf_available_ids
# 若文件存在，说明 eBPF 可用

# 检查内核配置
zcat /proc/config.gz | grep -E "BPF|CO-RE"
CONFIG_BPF=y
CONFIG_BPF_SYSCALL=y
CONFIG_BPF_JIT=y
CONFIG_DEBUG_INFO_BTF=y
```

---

## 2. Helm 安装详解

### 2.1 添加 Helm 仓库

```bash
# 添加 Cilium 仓库
helm repo add cilium https://helm.cilium.io/

# 更新仓库索引
helm repo update

# 确认版本
helm search repo cilium/cilium --versions
NAME            CHART VERSION   APP VERSION
cilium/cilium   1.14.6          1.14.6
cilium/cilium   1.15.0          1.15.0
cilium/cilium   1.16.0          1.16.0
```

### 2.2 生成配置

生产环境不应使用默认配置，而是根据集群特性定制：

```bash
# 导出默认配置到文件
helm template cilium/cilium \
  --namespace kube-system \
  --set ipam.operator.mode=cluster-pool \
  > cilium-default.yaml

# 使用官方配置生成器（推荐）
cilium config generate-helmvalues \
  --cluster-name my-cluster \
  --output-file cilium-values.yaml
```

### 2.3 关键配置项

```yaml
# cilium-values.yaml - 生产级配置

# 集群配置
cluster:
  name: my-production-cluster
  id: 1 # 集群 ID，Cluster Mesh 时必填

# IPAM 配置
ipam:
  mode: cluster-pool # 生产推荐 cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList: 10.0.0.0/8
    clusterPoolIPv4MaskSize: 24

# 运营商配置
operator:
  replicas: 2 # 生产环境至少 2 个
  unrollPrunedEndpoints: false

# eBPF 配置
bpf:
  mode: native # 高性能模式
  clockProbe: true
  hostRouting: true # 需要 kernel 5.10+

# 负载均衡器
loadBalancer:
  algorithm: weighted-round-robin
  mode: hybrid # snat + dsr 混合
  acceleration: always # 启用 XDP 加速

#kubeProxyReplacement 配置
kubeProxyReplacement: strict # strict 或 partial

# Hubble 观测（生产推荐开启）
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
  metrics:
    enabled:
      - flow:enable:流量
      - dns:delete:删除的 DNS 查询
      - port-distribution:端口分布

# 带宽管理器
bandwidth-manager:
  enabled: true
  # BBR 需要内核 5.18+
  # bbr: true

# 加密（可选）
encryption:
  type: wireguard
  # ipsec: 可选 IPsec
```

### 2.4 执行安装

```bash
# 创建 namespace
kubectl create namespace kube-system

# 使用 Helm 安装
helm install cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  --set nodeinit.enabled=true \  # 需要时启用
  --set cni.exclusive=false      # 允许多 CNI

# 验证安装
cilium status --wait

# 查看 Agent 状态
kubectl -n kube-system get pods -l k8s-app=cilium
```

---

## 3. 配置选项详解

### 3.1 kubeProxyReplacement

这是最重要的配置项，决定 Cilium 如何替代 kube-proxy：

| 值         | 说明              | 使用场景     |
| :--------- | :---------------- | :----------- |
| `disabled` | 不替代 kube-proxy | 兼容性测试   |
| `partial`  | 部分替代          | 迁移阶段     |
| `strict`   | 完全替代          | **生产推荐** |

```yaml
# strict 模式要求所有节点都有 matching 配置
kubeProxyReplacement: strict

# 检查节点是否满足 strict 模式要求
cilium sysdump check-requirements
```

### 3.2 IPAM 模式选择

```
┌─────────────────────────────────────────────────────────────────────┐
│                        IPAM 模式对比                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   模式             │   优点               │   缺点                   │
│   ─────────────────┼────────────────────┼─────────────────────────  │
│   cluster-pool     │ 简单、自动分配        │ Pod IP 跨节点不连续       │
│   (生产推荐)        │                    │                          │
│   ─────────────────┼────────────────────┼─────────────────────────  │
│   kubernetes       │ 与 K8s IPAM 兼容     │ 依赖 K8s IPAM           │
│   ─────────────────┼────────────────────┼─────────────────────────  │
│   static           │ 完全控制             │ 手动管理                 │
│   ─────────────────┼────────────────────┼─────────────────────────  │
│   aws-cni          │ AWS 原生            │ 平台绑定                 │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.3 负载均衡器配置

```yaml
# L4 负载均衡配置
loadBalancer:
  # 调度算法
  algorithm: Maglev # maglev | round_robin | weighted_round_robin | random

  # 模式
  mode: snat # snat | dsr | hybrid
  # SNAT: 出口转换，DSR: 直接返回，Hybrid: 智能选择

  # XDP 加速
  acceleration: always # always | opt-in | disabled

  # LRU 缓存大小
  lruMapSize: 65536

# 故障转移配置
l2PodBalancer:
  enabled: true
```

### 3.4 带宽管理器

```yaml
bandwidth-manager:
  enabled: true

# 启用 BBR 拥塞控制（需要内核 5.18+）
# bbr: true

# 启用 EDT（Earliest Departure Time）
# edt: true
```

---

## 4. 节点初始化

### 4.1 nodeinit 组件

某些 Kubernetes 集群（特别是 kubeadm 初始化的）需要 Cilium Node Init 来配置底层网络：

```yaml
nodeinit:
  enabled: true
  # 配合 kubeadm 使用时启用
  # 会自动配置:
  # - Pod CIDR 到节点
  # - CNI 配置
  # - hostname DNS 解析
```

### 4.2 主机路由

`hostRouting: true` 需要内核 5.10+ 并启用 BPF HOST ROUTING：

```bash
# 检查主机路由是否启用
cilium config view | grep host-routing
host-routing-enabled = true

# 如果未启用，检查内核版本
uname -r | grep -E "^5\.(10|11|12|13|14|15|16|17|18)"
```

---

## 5. CNI 配置

### 5.1 独占模式 vs 链式模式

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CNI 模式选择                                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   独占模式 (exclusive=true)          链式模式 (chaining)              │
│   ─────────────────────────          ───────────────────             │
│                                                                     │
│   ┌─────────────────────┐            ┌─────────────────────┐        │
│   │       Cilium        │            │   其他 CNI          │        │
│   │   完全接管网络        │            │   (Flannel 等)       │        │
│   └─────────────────────┘            └──────────┬──────────┘        │
│                                                  │                    │
│                                                  ▼                    │
│                                        ┌─────────────────────┐        │
│                                        │      Cilium         │        │
│                                        │   补充网络策略        │        │
│                                        └─────────────────────┘        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 链式模式配置

```yaml
# 与 Flannel 链式
cni:
  chainingMode: flannel
  exclusive: false

# 与 AWS VPC CNI 链式
cni:
  chainingMode: aws-cni
  exclusive: false

# 与 Calico 链式
cni:
  chainingMode: calico
  exclusive: false
```

---

## 6. 多集群配置

### 6.1 Cluster Mesh 前提

```yaml
# 启用 Cluster Mesh
clustermesh:
  enabled: true
  useAPIServer: true

# 每个集群必须有唯一 cluster ID
cluster:
  id: 1 # 集群 1
  # id: 2  # 集群 2
```

### 6.2 跨集群网络

```yaml
# 外部集群连接
clustermesh:
  apiserver:
    address: cluster2.internal.com
    port: 2379
```

---

## 7. 身份认证与安全

### 7.1 透明加密

```yaml
# WireGuard 加密（推荐）
encryption:
  type: wireguard
  # 节点间流量加密

# IPsec 加密（兼容旧版本）
encryption:
  type: ipsec
  keyFile: /var/lib/cilium/ipsec-keys
```

### 7.2 本地 CA 配置

```yaml
# 自定义 CA（可选）
ca:
  cert: |
    -----BEGIN CERTIFICATE-----
    ...
    -----END CERTIFICATE-----
  key: |
    -----BEGIN PRIVATE KEY-----
    ...
    -----END PRIVATE KEY-----
```

---

## 8. 升级前检查

### 8.1 系统要求检查

```bash
# 官方检查工具
cilium sysdump check-requirements

# 预期输出
[INFO] Kubernetes: 1.27.0
[INFO] Kernel: 5.10.0-generic
[INFO] eBPF: enabled
[INFO] All requirements met ✓
```

### 8.2 配置验证

```bash
# 验证 Helm 配置
helm template cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  --dry-run=server

# 检查生成的 ConfigMap
helm template cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  | kubectl diff -f -
```

---

## 9. 生产环境清单

```
┌─────────────────────────────────────────────────────────────────────┐
│                    生产环境安装检查清单                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   基础设施                                                             │
│   □ Kubernetes 1.24+ (推荐 1.27+)                                    │
│   □ 节点内核 5.10+ (推荐 5.15+)                                       │
│   □ etcd 集群或 kvstore 已配置                                        │
│   □ 足够的 etcd 存储空间                                              │
│                                                                     │
│   网络配置                                                             │
│   □ Pod CIDR 配置正确                                                │
│   □ Node CIDR 配置正确                                               │
│   □ CNI 模式选择（独占/链式）                                         │
│   □ kubeProxyReplacement=strict                                     │
│                                                                     │
│   高可用                                                             │
│   □ Operator replicas >= 2                                           │
│   □ Agent 容忍所有 Taint                                              │
│   □ Hubble Relay 已启用                                              │
│   □ Hubble UI 已启用                                                 │
│                                                                     │
│   安全                                                             │
│   □ 加密类型选择（WireGuard/IPsec）                                   │
│   □ 网络策略已定义                                                   │
│   □ 默认 deny 策略已配置                                             │
│                                                                     │
│   监控                                                             │
│   □ Prometheus 指标已导出                                            │
│   □ Hubble 流量可见性已启用                                          │
│   □ 日志收集已配置                                                    │
│                                                                     │
│   备份                                                             │
│   □ etcd 备份已配置                                                   │
│   □ Cilium ConfigMap 已备份                                          │
│   □ 证书已备份                                                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 10. 验证安装

### 10.1 基本状态检查

```bash
# 查看 Cilium 状态
cilium status

# 详细状态
cilium status --verbose

# 查看所有节点
cilium node list

# 查看端点
cilium endpoint list
```

### 10.2 连通性测试

```bash
# 部署连通性测试
cilium connectivity test

# 仅测试 enpoint 连通性
cilium connectivity test --test=pod-to-pod

# 测试外网连通性
cilium connectivity test --test=pod-to-external
```

### 10.3 Hubble 验证

```bash
# 检查 Hubble Relay
cilium hubble status

# 查看实时流量
hubble observe --to-pod kube-system:cilium-

# 检查 Hubble UI
kubectl -n kube-system get pods -l k8s-app=hubble-ui
```

---

## 11. 常见问题

### 11.1 安装失败排查

| 问题               | 原因           | 解决方案                         |
| :----------------- | :------------- | :------------------------------- |
| Agent 无法启动     | 内核不支持     | 升级内核到 5.10+                 |
| Agent 无法启动     | eBPF 系统限制  | 检查 `/proc/sys/kernel/bpf_max*` |
| Operator 无法启动  | RBAC 问题      | 检查 ClusterRole                 |
| Hubble UI 无法访问 | 未配置 Ingress | 配置 Ingress 或 NodePort         |

### 11.2 性能问题

| 问题       | 原因               | 解决方案                    |
| :--------- | :----------------- | :-------------------------- |
| 高延迟     | hostRouting 未启用 | 启用 `bpf.hostRouting=true` |
| 高 CPU     | 规则过多           | 启用 LRU 缓存               |
| 内存占用高 | Map 大小过大       | 调小 `bpf.*MapSize`         |

---

## 12. 下一步

安装完成后，下一章将讲解 [[2026-04-14-cilium-deep-dive-ch40-upgrade| Cilium 升级策略]]，包括滚动升级、ConfigMap 迁移和数据面重启的最佳实践。
