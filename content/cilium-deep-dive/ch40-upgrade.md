---
title: "Cilium 深度探索 (40)：升级策略与最佳实践"
date: 2026-04-14
tags:
  - cilium
  - upgrade
  - rolling-update
  - migration
  - operations
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 38. [[ch38-sockmap|第三十八章：Sockmap]] 39. [[ch39-install|第三十九章：生产级安装指南]] 40. **第四十章：升级策略与最佳实践** ← 41. [[ch41-debug|第四十一章：故障诊断]] 42. [[ch42-performance|第四十二章：性能调优]]

---

## 1. 升级概述

Cilium 采用**原地升级**模式，Agent 和 Operator 可以滚动更新而无需重启节点。eBPF 程序通过 `bpf(2)` 系统调用的版本机制实现热更新，确保升级过程中服务零中断。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Cilium 升级架构                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   升级前                        升级中                          升级后  │
│                                                                     │
│   ┌─────────────┐              ┌─────────────┐              ┌─────────────┐ │
│   │ Cilium 1.14 │              │ 1.14 → 1.15 │              │  Cilium 1.15│ │
│   │             │              │             │              │             │ │
│   │ ┌─────────┐ │              │ ┌─────────┐ │              │ ┌─────────┐ │ │
│   │ │ Agent   │ │              │ │ Agent   │ │              │ │ Agent   │ │ │
│   │ │ 1.14    │ │              │ │ 1.15    │ │              │ │ 1.15    │ │ │
│   │ └─────────┘ │              │ └─────────┘ │              │ └─────────┘ │ │
│   │             │              │             │              │             │ │
│   │ ┌─────────┐ │              │ ┌─────────┐ │              │ ┌─────────┐ │ │
│   │ │ eBPF    │ │──────────────▶│ │ eBPF    │ │─────────────▶│ │ eBPF    │ │ │
│   │ │ Prog    │ │   热更新      │ │ Prog    │ │   验证       │ │ Prog    │ │ │
│   │ │ 1.14    │ │              │ │ 1.15    │ │              │ │ 1.15    │ │ │
│   │ └─────────┘ │              │ └─────────┘ │              │ └─────────┘ │ │
│   └─────────────┘              └─────────────┘              └─────────────┘ │
│                                                                     │
│   特性:                                                               │
│   • Agent 滚动重启，不丢流量                                           │
│   • eBPF 程序热更新，现有关注连接不断                                   │
│   • Operator 优先升级                                                │
│   • 失败自动回滚                                                      │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 版本支持策略

| 版本类型                    | 支持周期 | 说明              |
| :-------------------------- | :------- | :---------------- |
| **LTS (Long Term Support)** | 2 年     | 1.14.x, 1.15.x 等 |
| **Stable**                  | 6 个月   | 最新 stable 版本  |
| **Main**                    | 开发版   | 不推荐生产使用    |

```
推荐升级路径:
1.13.x → 1.14.x (LTS) → 1.15.x (LTS) → 1.16.x (LTS)
   ↓
避免跳版本升级，每次只升一个 minor 版本
```

### 1.2 升级风险评估

| 风险级别 | 影响       | 缓解措施           |
| :------- | :--------- | :----------------- |
| **低**   | 功能更新   | 自动测试验证       |
| **中**   | 配置变更   | ConfigMap 渐进更新 |
| **高**   | 数据面变更 | 预留维护窗口       |

---

## 2. 升级前准备

### 2.1 集群状态检查

```bash
# 检查当前版本
cilium version
Client: 1.14.6
Server: 1.14.6 (running on cluster)

# 检查集群健康状态
cilium status

# 检查所有节点状态
cilium node list

# 验证所有端点健康
cilium endpoint list | grep -v "ready"
# 无输出表示所有端点就绪
```

### 2.2 etcd/kvstore 检查

```bash
# 检查 etcd 延迟
cilium kvstore get cilium/state/nodes --timeout 5s

# 备份 etcd 数据（重要！）
etcdctl snapshot save cilium-backup.db

# 检查 kvstore 连接数
cilium config view | grep kvstore
kvstore-logical-clock=disabled
```

### 2.3 配置备份

```bash
# 备份当前配置
kubectl get configmap cilium-config -n kube-system -o yaml > cilium-config-backup.yaml

# 备份 Agent 日志配置
kubectl get configmap cilium-agent-conf -n kube-system -o yaml > cilium-agent-conf-backup.yaml

# 导出所有 Cilium CRD
kubectl get crd -o yaml ciliumendpoints.cilium.io > cilium-crd-backup.yaml
```

### 2.4 创建升级快照

```bash
# 使用 sysdump 收集完整状态
cilium sysdump --output-filename pre-upgrade

# 或者手动收集关键信息
kubectl get all -n kube-system -l k8s-app=cilium -o yaml > cilium-resources.yaml
kubectl get nodes -o yaml > nodes.yaml
```

---

## 3. 升级步骤

### 3.1 Operator 优先升级

Cilium Operator 是控制面核心，应首先升级：

```bash
# 方式一：Helm 升级（推荐）
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  --set operator.enabled=true \
  --set operator.image.repository=quay.io/cilium/operator \
  --set operator.image.tag=1.15.0 \
  --timeout 10m

# 方式二：直接升级
kubectl set image deployment/cilium-operator \
  -n kube-system \
  operator=quay.io/cilium/operator:1.15.0

# 监控 Operator 升级
kubectl rollout status deployment/cilium-operator -n kube-system --timeout=300s
```

### 3.2 Agent 滚动升级

Agent 升级会触发每个节点的 DaemonSet滚动更新：

```bash
# 升级 Agent
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  --set agent=true \
  --set nodeinit.enabled=true \
  --wait \
  --timeout 30m

# 或者手动触发滚动更新
kubectl rollout restart daemonset/cilium -n kube-system

# 监控滚动更新进度
kubectl rollout status daemonset/cilium -n kube-system --timeout=600s
```

### 3.3 滚动更新策略

```yaml
# DaemonSet 滚动更新配置
spec:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 1 # 每次最多不可用 1 个节点
      maxSurge: 1 # 允许最多超出 1 个节点
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Agent 滚动更新流程                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Node-1          Node-2          Node-3          Node-4           │
│   ──────          ──────          ──────          ──────           │
│                                                                     │
│   Agent 1.14  →   Agent 1.14  →   Agent 1.14  →   Agent 1.14        │
│      │              │              │              │                 │
│      ▼ (开始)        │              │              │                 │
│   Agent 1.15       Agent 1.14      Agent 1.14      Agent 1.14        │
│      │              │              │              │                 │
│      │  (完成)       ▼ (开始)        │              │                 │
│      │           Agent 1.15       Agent 1.14      Agent 1.14        │
│      │              │              │              │                 │
│      │              │  (完成)        ▼ (开始)        │                 │
│      │              │           Agent 1.15       Agent 1.14          │
│      │              │              │              │                 │
│      │              │              │  (完成)        ▼ (开始)         │
│      ▼              ▼              ▼           Agent 1.15          │
│   Agent 1.15      Agent 1.15      Agent 1.15      Agent 1.15         │
│                                                                     │
│   原则: 每次最多 1 个节点不可用，连接自动迁移到其他节点                │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 3.4 Hubble 升级

如果启用了 Hubble，升级时需要考虑顺序：

```bash
# 1. 先升级 Relay
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set hubble.relay.image.repository=quay.io/cilium/hubble-relay \
  --set hubble.relay.image.tag=1.15.0

# 2. 升级 Agent（包含 Hubble agent）
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values

# 3. 最后升级 UI
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set hubble.ui.enabled=true
```

---

## 4. 配置迁移

### 4.1 ConfigMap 变更处理

Cilium 升级可能伴随 ConfigMap 变更：

```bash
# 查看 ConfigMap 差异
diff <(kubectl get configmap cilium-config -n kube-system -o yaml) \
     <(helm template cilium/cilium --namespace kube-system | kubectl get -o yaml -f -)

# 应用配置变更（仅变更 ConfigMap）
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  --set agent.config=- \
  --no-hooks  # 跳过 DaemonSet 更新
```

### 4.2 破坏性配置变更

某些配置变更需要特殊处理：

| 配置项                 | 变更类型 | 处理方式           |
| :--------------------- | :------- | :----------------- |
| `bpf.hostRouting`      | 可能破坏 | 升级完成后手动启用 |
| `kubeProxyReplacement` | 破坏性   | 预留维护窗口       |
| `ipam.mode`            | 破坏性   | 不支持在线变更     |
| `encryption.type`      | 破坏性   | 预留维护窗口       |

```bash
# 检查是否有破坏性变更
cilium config check-upgrade --output markdown

# 预期输出示例
## Configuration changes from 1.14.6 to 1.15.0

### Potentially disruptive changes:
- bpf.clockProbe: default changed from 'false' to 'true'
  → May require node reboot if TSC clock is unavailable
```

### 4.3 CRD 迁移

Cilium 1.15+ 引入了新的 CRD：

```bash
# 查看 CRD 变更
kubectl get crd ciliumbgppeeringpolicies.cilium.io -o yaml > /dev/null 2>&1
echo "BGPPeerings CRD: $(kubectl get crd ciliumbgppeeringpolicies.cilium.io 2>/dev/null && echo 'exists' || echo 'missing')"

# 升级前备份 CRD
kubectl get ciliumidentities -A -o yaml > ciliumidentities-backup.yaml
kubectl get ciliumendpoints -A -o yaml > ciliumendpoints-backup.yaml
```

---

## 5. 数据面重启

### 5.1 何时需要数据面重启

以下情况需要数据面（eBPF 程序）重启：

| 场景              | 影响           | 处理           |
| :---------------- | :------------- | :------------- |
| 内核版本升级      | 必须重启 Agent | 节点 Drain     |
| eBPF Map 结构调整 | 必须重启 Agent | 滚动更新       |
| 底层内核 bug      | 必须重启 Agent | 紧急修复       |
| 配置变更 `bpf.*`  | 通常热更新     | 特殊情况需重启 |

### 5.2 平滑重启流程

```bash
# 1. 标记节点为维护模式
kubectl annotate node node-1 cilium.io/node-operator-out-of-period-rebuild=true

# 2. 驱逐 Pod
kubectl drain node-1 --ignore-daemonsets --delete-emptydir-data

# 3. 重启 Cilium Agent
systemctl restart cilium-agent

# 4. 验证 eBPF 程序加载
cilium bpf prog list

# 5. 恢复节点
kubectl uncordon node-1

# 6. 验证连接
cilium connectivity test --test=pod-to-pod
```

### 5.3 eBPF Map 检查

```bash
# 查看所有 eBPF Maps
cilium bpf map list

# 查看特定 Map
cilium bpf map get cilium_ipmasq

# 检查 Map 统计
cilium bpf map list -o json | jq '.[] | select(.name=="cilium_lb4_services_v2")'
```

---

## 6. 回滚策略

### 6.1 自动回滚

Helm 升级失败时自动回滚：

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --values cilium-values.yaml \
  --atomic \        # 启用自动回滚
  --timeout 10m

# 如果失败，自动回滚到上一个成功版本
```

### 6.2 手动回滚

```bash
# 列出最近 5 次发布
helm history cilium -n kube-system

# 回滚到指定版本
helm rollback cilium 3 -n kube-system

# 手动恢复 Agent
kubectl rollout undo daemonset/cilium -n kube-system
kubectl rollout undo deployment/cilium-operator -n kube-system
```

### 6.3 回滚检查清单

```
回滚后必做检查:
□ Agent 版本正确
□ 所有端点状态 ready
□ 关键连接正常
□ Hubble 流量可见
□ 网络策略生效
□ Hubble Flow 正常
```

---

## 7. 升级验证

### 7.1 基本验证

```bash
# 检查版本
cilium version
# Client: 1.15.0
# Server: 1.15.0

# 检查状态
cilium status

# 检查节点
cilium node list

# 检查端点
cilium endpoint list
```

### 7.2 连通性验证

```bash
# 运行完整连通性测试
cilium connectivity test

# 只测试特定场景
cilium connectivity test --test=pod-to-pod,pod-to-external,node-to-node

# 检查 DNS 解析
cilium connectivity test --test=dns

# 检查 L7 策略
cilium connectivity test --test=l7-policy
```

### 7.3 性能验证

```bash
# 检查延迟
cilium bpf metrics list | grep -E "srv6|datapath"

# 检查吞吐量
cilium bpf metrics list | grep -E "forward|承接"

# 比较升级前后指标
cilium metrics export | grep cilium_
```

---

## 8. 升级后优化

### 8.1 利用新特性

Cilium 1.15 新特性：

| 特性                      | 说明          | 启用方式                            |
| :------------------------ | :------------ | :---------------------------------- |
| **Bandwidth Manager EDT** | 更好的限速    | `bandwidth-manager.edt=true`        |
| **bpf.clockProbe**        | 跨时区兼容性  | 自动启用                            |
| **Hubble Flow Logs**      | 改进的日志    | `--set hubble.flowLog.enabled=true` |
| **L7 DNS Policy**         | 增强 DNS 策略 | CRD 自动创建                        |

### 8.2 配置清理

```bash
# 列出废弃配置
cilium config list-obsolete

# 移除废弃配置
helm template cilium/cilium --show-only templates/configmap.yaml | grep -E "^[^-]{{" | head
```

---

## 9. 常见问题

### 9.1 升级失败排查

| 问题              | 原因                   | 解决方案             |
| :---------------- | :--------------------- | :------------------- |
| Agent 启动失败    | 内核不支持新 eBPF 程序 | 降级或升级内核       |
| Operator 无法启动 | RBAC 变更              | 重新应用 ClusterRole |
| etcd 写入失败     | 版本不兼容             | 使用新版本 etcdctl   |
| 连接中断          | 数据面重启             | 正常现象，验证恢复   |

### 9.2 性能下降

```bash
# 检查是否存在性能回退
cilium bpf metrics list

# 检查是否启用了非必要特性
cilium config view | grep -E "disable|tunnel|"

# 检查 MTU
ip link | grep cilium
```

---

## 10. 升级时间估算

| 集群规模    | 升级时间   | 说明         |
| :---------- | :--------- | :----------- |
| < 10 节点   | 5-10 分钟  | 快速滚动更新 |
| 10-50 节点  | 15-30 分钟 | 标准滚动更新 |
| 50-200 节点 | 30-60 分钟 | 批量滚动更新 |
| > 200 节点  | 60+ 分钟   | 分批升级     |

---

## 11. 下一步

完成升级后，下一章将讲解 [[ch41-debug| Cilium 故障诊断]]，包括使用 cilium CLI、Hubble Flow 排查常见问题。
