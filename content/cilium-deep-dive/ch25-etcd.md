---
title: "Cilium 深度探索 (25)：etcd kvstore 高可用部署"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - kubernetes
  - etcd
  - kvstore
  - high-availability
  - networking
  - cloud-native
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 23. [[ch23-cni-chain|第二十三章：CNI Chaining]] 24. [[ch24-ipam|第二十四章：IPAM]] 25. **第二十五章：etcd kvstore** ←

---

## 1. 概述

Cilium 的控制面和数据面都依赖 **etcd** 作为集群状态的持久化存储。etcd 在 Cilium 中承担关键职责：

- **IPAM 状态**：Pod IP 的分配与回收
- **Node 注册**：集群节点的心跳和拓扑
- **Global Service**：跨集群 Service 定义
- **Identity 管理**：安全身份的分配和撤销
- **Policy 存储**：网络策略的持久化

对于生产环境，etcd 的**高可用（HA）部署**是 필수（必要）的。

---

## 2. Cilium 为什么需要 etcd

### 2.1 与 Kubernetes etcd 的区别

```
┌─────────────────────────────────────────────────────────────────┐
│                 Cilium etcd vs Kubernetes etcd                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Kubernetes etcd                                                 │
│      │                                                          │
│      ├── 存储 API 对象（Pod, Service, Deployment 等）           │
│      ├── 由 kube-apiserver 读写                                 │
│      └── 是 K8s 控制面的核心                                    │
│                                                                  │
│  Cilium etcd                                                    │
│      │                                                          │
│      ├── 存储 Cilium 特定数据（IPAM, Node, Identity 等）         │
│      ├── 由 cilium-agent 直接读写                                │
│      └── 是 Cilium 数据面的协同组件                              │
│                                                                  │
│  两者完全独立，互不影响                                          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 Cilium etcd 数据类型

| 数据类型     | Key 模式                 | 说明                         |
| :----------- | :----------------------- | :--------------------------- |
| **Node**     | `cilium/nodes/v1/<node>` | 节点信息、Pod CIDR、隧道端点 |
| **IPAM**     | `cilium/ipam/v2/...`     | IP 地址分配状态              |
| **Identity** | `cilium/identity/v1/...` | 安全身份                     |
| **Service**  | `cilium/service/v1/...`  | Global Service 定义          |
| **Policy**   | `cilium/policy/v2/...`   | 网络策略规则                 |

### 2.3 数据流

```
┌─────────────────────────────────────────────────────────────────┐
│                      Cilium etcd 数据流                          │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  Cilium Agent (Node-A)                                          │
│      │                                                          │
│      ├── 写入: IPAM 分配 (10.1.0.10 → pod-xyz)                   │
│      ├── 写入: Node 注册 (node-A, 10.1.0.0/24)                   │
│      ├── 读取: 其他节点的 IPAM 状态                              │
│      ├── 读取: 全局 Policy 规则                                  │
│      └── 读取: Global Service 定义                               │
│                                                                  │
│                        etcd Cluster                             │
│                              │                                   │
│              ┌───────────────┼───────────────┐                  │
│              ▼               ▼               ▼                  │
│         ┌─────────┐     ┌─────────┐     ┌─────────┐             │
│         │  etcd-1 │     │  etcd-2 │     │  etcd-3 │             │
│         │(Leader) │◄───►│(Follow) │◄───►│(Follow) │             │
│         └─────────┘     └─────────┘     └─────────┘             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. etcd 高可用架构

### 3.1 推荐架构：3 节点集群

```
                    ┌─────────────────────────────────────┐
                    │         etcd High Availability        │
                    │              (3 节点)                  │
                    └─────────────────────────────────────┘
                              │              │              │
              ┌───────────────┘              │              └───────────────┐
              ▼                              ▼                              ▼
        ┌───────────┐                  ┌───────────┐                  ┌───────────┐
        │  etcd-1   │                  │  etcd-2   │                  │  etcd-3   │
        │ (Leader)  │◄─────────────────┤ (Follow)  │─────────────────►│ (Follow)  │
        └───────────┘                  └───────────┘                  └───────────┘
              │                              │                              │
              │   Raft 共识协议确保数据一致    │                              │
              └──────────────────────────────┘
```

### 3.2 故障容忍

| 节点数 | 容忍故障节点 | 说明                 |
| :----- | :----------- | :------------------- |
| 1      | 0            | 单点故障，不推荐生产 |
| 3      | 1            | 推荐最小生产配置     |
| 5      | 2            | 更高可靠性，延迟更高 |
| 7+     | 3            | 超大规模部署         |

### 3.3 选举机制

etcd 使用 **Raft 共识协议**：

1. **Leader 选举**：节点间通过心跳竞争 Leader
2. **日志复制**：所有写请求通过 Leader 复制到 Followers
3. **故障转移**：Leader 故障后自动选举新 Leader
4. **一致性保证**：多数节点确认后数据持久化

---

## 4. Cilium 内置 etcd 部署

### 4.1 通过 Helm 部署

```bash
# 部署 Cilium 时启用内置 etcd（3 节点）
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set etcd.enabled=true \
    --set etcd.replicas=3 \
    --set etcd.storageClass=gp3 \
    --set etcd.size=10Gi
```

### 4.2 etcd Operator 模式

Cilium 支持通过 etcd-operator 管理 etcd 集群：

```bash
# 1. 安装 etcd-operator
helm install etcd-operator bitnami/etcd \
    --namespace cilium-etcd \
    --create-namespace

# 2. 创建 etcd 集群
kubectl apply -f - <<EOF
apiVersion: etcd.database.coreos.com/v1beta2
kind: EtcdCluster
metadata:
  name: cilium-etcd
  namespace: cilium-etcd
spec:
  size: 3
  version: 3.5.9
  pod:
    etcdEnv:
    - name: ETCD_QUOTA_BACKEND_BYTES
      value: "8589934592"  # 8GB
 持久卷:
    storageClassName: gp3
    size: 10Gi
EOF
```

### 4.3 外部 etcd 集群

对于已有 etcd 基础设施的环境：

```bash
# 配置 Cilium 连接外部 etcd
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set etcd.enabled=true \
    --set etcd.endpoints[0]=https://etcd-1:2379 \
    --set etcd.endpoints[1]=https://etcd-2:2379 \
    --set etcd.endpoints[2]=https://etcd-3:2379 \
    --set etcd.tls.enabled=true \
    --set etcd.tls.caCert=/var/lib/etcd/ca.crt \
    --set etcd.tls.cert=/var/lib/etcd/tls.crt \
    --set etcd.tls.key=/var/lib/etcd/tls.key
```

---

## 5. 性能优化

### 5.1 硬件要求

| 资源     | 最低      | 推荐            | 说明             |
| :------- | :-------- | :-------------- | :--------------- |
| **CPU**  | 2 核      | 4+ 核           | Raft 共识处理    |
| **内存** | 4 GB      | 8+ GB           | 数据缓存         |
| **磁盘** | 20 GB SSD | 50+ GB NVMe SSD | WAL 写入延迟关键 |
| **网络** | 1 Gbps    | 10 Gbps         | 节点间通信       |

### 5.2 参数调优

```yaml
# etcd 启动参数优化
apiVersion: v1
kind: ConfigMap
metadata:
  name: cilium-etcd
  namespace: kube-system
data:
  etcd-config: |
    --heartbeat-interval=500
    --election-timeout=2500
    --snapshot-count=5000
    --max-wals=5
    --quota-backend-bytes=8589934592  # 8GB
    --auto-compaction-mode=revision
    --auto-compaction-retention=1000
```

关键参数：

| 参数                    | 说明           | 推荐值 |
| :---------------------- | :------------- | :----- |
| `--heartbeat-interval`  | 心跳间隔（ms） | 500    |
| `--election-timeout`    | 选举超时（ms） | 2500   |
| `--snapshot-count`      | 快照间隔       | 5000   |
| `--quota-backend-bytes` | DB 大小限制    | 8GB    |

### 5.3 监控指标

```bash
# 通过 Prometheus 监控 etcd
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cilium-etcd
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: etcd
  endpoints:
    - port: metrics
      interval: 30s
EOF
```

关键指标：

| 指标                                        | 说明            | 告警阈值       |
| :------------------------------------------ | :-------------- | :------------- |
| `etcd_server_leader_changes`                | Leader 变更次数 | > 5/分钟       |
| `etcd_mvcc_db_total_size_in_bytes`          | DB 大小         | > quota 的 80% |
| `etcd_server_slow_apply`                    | 慢请求          | > 0.5s         |
| `etcd_network_peer_round_trip_time_seconds` | 节点延迟        | > 0.5s         |

---

## 6. 备份与恢复

### 6.1 自动备份

Cilium 支持自动快照 etcd：

```bash
# 配置自动快照
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set etcd.backup.enabled=true \
    --set etcd.backup.schedule="0 */6 * * *"  # 每 6 小时
    --set etcd.backup.retention=7             # 保留 7 份
    --set etcd.backup.storageClass=gp3
```

### 6.2 手动备份

```bash
# 连接到 etcd 容器
kubectl -n kube-system exec -it cilium-etcd-0 -- etcdctl \
    --endpoints=https://localhost:2379 \
    --cacert=/etc/ssl/certs/etcd-ca.crt \
    --cert=/etc/ssl/certs/etcd-server.crt \
    --key=/etc/ssl/private/etcd-server.key \
    snapshot save /var/backup/etcd-snap-$(date +%Y%m%d).db
```

### 6.3 恢复流程

```bash
# 1. 停止所有 Cilium Agent
kubectl scale deployment cilium-operator --replicas=0 -n kube-system
kubectl scale daemonset cilium --replicas=0 -n kube-system

# 2. 从快照恢复 etcd
kubectl -n kube-system exec -it cilium-etcd-0 -- etcdctl \
    snapshot restore /var/backup/etcd-snap-20260414.db \
    --name=cilium-etcd-0 \
    --initial-cluster=cilium-etcd-0=http://cilium-etcd-0:2380,cilium-etcd-1=http://cilium-etcd-1:2380,cilium-etcd-2=http://cilium-etcd-2:2380 \
    --initial-cluster-token=cilium-etcd-token \
    --initial-advertise-peer-urls=http://cilium-etcd-0:2380

# 3. 重启 etcd 集群
kubectl rollout restart statefulset/cilium-etcd -n kube-system

# 4. 恢复 Cilium Agent
kubectl scale daemonset cilium --replicas=3 -n kube-system
kubectl scale deployment cilium-operator --replicas=2 -n kube-system
```

---

## 7. TLS 安全配置

### 7.1 证书配置

```bash
# 生成 etcd CA 和证书（使用 cfssl 或 openssl）
# ...

# 通过 Helm 配置 TLS
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set etcd.tls.enabled=true \
    --set etcd.tls.caCertSecret=cilium-etcd-ca \
    --set etcd.tls.certSecret=cilium-etcd-cert \
    --set etcd.tls.keySecret=cilium-etcd-cert-key
```

### 7.2 强制 TLS

```bash
# 禁止非 TLS 连接
helm upgrade cilium cilium/cilium \
    --namespace kube-system \
    --set etcd.tls.enabled=true \
    --set etcd.tls.forceSSL=true
```

---

## 8. 故障排查

### 8.1 常见问题

| 问题                            | 原因          | 解决方案            |
| :------------------------------ | :------------ | :------------------ |
| `context deadline exceeded`     | etcd 连接超时 | 检查网络、防火墙    |
| `etcd cluster is unavailable`   | 多数节点故障  | 增加节点数，确保 3+ |
| `mvcc: database space exceeded` | DB 配额用尽   | 压缩 DB，增加配额   |
| `request is too large`          | 请求过大      | 减少批量操作        |

### 8.2 诊断命令

```bash
# 检查 etcd 端点健康
kubectl -n kube-system exec ds/cilium -- cilium etcd status

# 输出示例
/var/lib/cilium/etcd:
  Endpoints: https://10.0.0.1:2379, https://10.0.0.2:2379, https://10.0.0.3:2379
  Leader: https://10.0.0.1:2379
  Health: true
  Connected: true
  Version: 3.5.9

# 检查 etcd 日志
kubectl -n kube-system logs -l app=etcd --tail=100

# 检查磁盘延迟
kubectl -n kube-system exec etcd-0 -- -- sh -c 'dd if=/dev/zero of=./test bs=64k count=1000 oflag=direct'
```

---

## 9. 章节总结

| 概念                   | 说明                                  |
| :--------------------- | :------------------------------------ |
| **Cilium etcd**        | 独立于 K8s etcd，存储 Cilium 专用数据 |
| **Raft 共识**          | etcd 的分布式一致性协议               |
| **3 节点 HA**          | 生产环境最小推荐配置                  |
| **IPAM/Identity/Node** | 存储在 etcd 中的关键数据类型          |
| **TLS 安全**           | 加密 etcd 通信，推荐生产环境启用      |
| **备份恢复**           | 快照备份 + 恢复流程                   |

---

## 参考资料

- [Cilium etcd Documentation](https://docs.cilium.io/en/stable/operations/etcd/)
- [etcd Official Documentation](https://etcd.io/docs/)
- [Cilium Architecture - kvstore](https://docs.cilium.io/en/stable/architecture/architecture/#kvstore)
