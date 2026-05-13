---
title: "Cilium 深度探索 (6)：ClusterIP 服务发现"
date: 2026-04-14
tags:
  - cilium
  - clusterip
  - service
  - ebpf
  - kubernetes
  - networking
  - load-balancer
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. **第六章：ClusterIP** ←

---

## 1. ClusterIP 概述

ClusterIP 是 Kubernetes Service 的核心类型，它为集群内部提供稳定的虚拟 IP（VIP），屏蔽后端 Pod 的动态 IP 变化。在 Cilium 中，ClusterIP 完全由 **eBPF Service 映射** 实现，绕过 iptables/IPVS，提供 O(1) 查找性能。

```
┌─────────────────────────────────────────────────────────────┐
│                  Kubernetes Cluster                         │
│                                                             │
│   Pod A (10.0.1.10)                                        │
│        │                                                   │
│        │ 访问 my-svc.default.svc.cluster.local            │
│        │ (ClusterIP: 10.96.0.100)                          │
│        ▼                                                    │
│   ┌─────────────────────────────────────────────────────┐   │
│   │      cilium_services Map (eBPF)                     │   │
│   │                                                    │   │
│   │   Key: {10.96.0.100, 80, TCP}                      │   │
│   │   Value: {Backends: [10.0.2.1:8080, 10.0.2.2:8080]}│   │
│   │                                                    │   │
│   │   O(1) 哈希查找，而非 iptables 遍历                │   │
│   └─────────────────────────────────────────────────────┘   │
│                         │                                   │
│                         ▼                                   │
│   ┌─────────────────────────────────────────────────────┐   │
│   │              负载均衡 → Backend Pod                  │   │
│   │                                                    │   │
│   │   10.0.2.1:8080  ←── 轮询/最少连接/Maglev          │   │
│   │   10.0.2.2:8080                                    │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 ClusterIP 地址池

Cilium 通过 Kubernetes Service 的 `clusterIP` 字段或自动分配获取 ClusterIP：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: ClusterIP # 默认类型，可省略
  clusterIP: 10.96.0.100 # 指定 ClusterIP
  ports:
    - port: 80
      targetPort: 8080
```

**自动分配的 ClusterIP 范围**由 Kubernetes API Server 的 `--service-cluster-ip-range` 参数控制，Cilium 通过 watch Kubernetes Service 资源获取分配的 IP。

---

## 2. eBPF Service 映射原理

### 2.1 cilium_services Map

Cilium 使用 `cilium_services` 这个 **LPM（Longest Prefix Match）eBPF Map** 存储 ClusterIP 到后端的映射：

```c
// 头文件：include/bpf/lib/services.h

struct cluster_service_key {
    __u32 cluster_id;    // 集群 ID（多集群场景）
    __u32 address;       // ClusterIP (大端序 Network Byte Order)
    __u16 port;          // Service Port (大端序)
    __u8  proto;         // 协议：TCP(6) / UDP(17)
    __u8  pad;            // 对齐填充
};

// 存储格式
struct cluster_service_value {
    __u32 backend_count;              // 后端数量
    __u32 backend_ids[16];            // 后端 ID 数组（最多 16 个）
    __u32 flags;                      // 标志：local-backends / session-affinity
    __u32 session_affinity_timeout;   // 会话亲和超时（秒）
    __u32 src_range_len;              // 源 IP 范围长度
    __u32 src_range[2];               // 源 IP 范围（CIDR）
};
```

**LPM 特性**：支持最长前缀匹配，允许 ClusterIP 范围作为一个条目而非每个 IP 一条，节省 Map 空间。

### 2.2 Backend 存储

后端信息单独存储在 `cilium_backend` Map 中：

```c
struct backend_key {
    __u32 id;    // Backend ID（由 Cilium 分配）
};

struct backend_value {
    __u32 addr;         // Pod IP（主机字节序）
    __u16 port;         // Pod Port
    __u8  proto;        // 协议
    __u8  flags;        // 状态：active / terminating / idle
    __u32 refcount;     // 引用计数
    __u32 used;         // 使用计数（统计）
};
```

### 2.3 Service 查找流程

```
数据包（目标：ClusterIP:Port）
    │
    ▼
TC Ingress Hook（cilium_veth ethX）
    │
    ▼
提取 {dst_ip, dst_port, protocol}
    │
    ▼
bpf_map_lookup_elem(&cilium_services, &key)  ← O(1) 查找
    │
    ├─── 命中 ───→ 获取 backend_ids[]
    │                    │
    │                    ▼
    │              负载均衡算法选择后端
    │                    │
    │                    ▼
    │              执行 DNAT（ClusterIP → BackendIP）
    │                    │
    │                    ▼
    │              转发到 Backend Pod
    │
    └─── 未命中 ───→ 交给上层协议栈处理
```

### 2.4 负载均衡算法

Cilium 支持四种负载均衡算法：

| 算法                           | 实现       | 说明                                   |
| :----------------------------- | :--------- | :------------------------------------- |
| **RR (Round Robin)**           | 简单轮询   | 默认，每个请求轮换后端                 |
| **LC (Least Connection)**      | 连接计数   | 选择当前连接数最少的后端               |
| **DSR (Direct Server Return)** | 跳过 SNAT  | 响应直接返回客户端，不经过中转         |
| **Maglev**                     | 一致性哈希 | 同源 IP 总是映射到同一后端（会话保持） |

```bash
# 配置负载均衡算法
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ebpF.loadBalancer.algorithm=least_connections

# 或通过 ConfigMap
kubectl edit configmap cilium-config -n kube-system
```

---

## 3. ClusterIP 分配机制

### 3.1 Kubernetes Service 控制器

Kubernetes API Server 在创建 ClusterIP Service 时：

1. 验证 `clusterIP` 字段（若指定）
2. 若未指定，从 `service-cluster-ip-range` 分配可用 IP
3. 将 ClusterIP 写入 etcd

```bash
# 查看 Kubernetes Service ClusterIP 范围
kubectl get pod kube-apiserver -n kube-system -o yaml | grep -A5 service-cluster-ip-range
# 或者
cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep service-cluster-ip-range
```

### 3.2 Cilium 的 Service 同步

Cilium Agent 通过 **Kubernetes Service Watch** 获取 Service 变化：

```
Kubernetes API Server
        │
        │ Service Created/Updated/Deleted
        ▼
Cilium Agent (每个节点)
        │
        ▼
    1. 解析 Service.spec.clusterIP + spec.ports
        │
        ▼
    2. 获取 Endpoint（后端 Pod IP + Port）
        │
        ▼
    3. 构造 cilium_service_key + cilium_service_value
        │
        ▼
    4. 调用 bpf_map_update_elem() 更新 eBPF Map
        │
        ▼
    5. 同步 cilium_backend Map（添加/删除后端）
```

### 3.3 ClusterIP 冲突检测

当多个 Service 使用相同 ClusterIP 时：

```bash
# Kubernetes API Server 会拒绝冲突的 Service 创建
# 错误示例：
# The Service "my-app" is invalid: spec.clusterIP: Invalid value: "10.96.0.1":
# Service "kube-dns" already uses this clusterIP
```

Cilium 通过 `cilium_service_ids` Map 追踪已分配的 ClusterIP，防止 eBPF 侧冲突。

---

## 4. Session Affinity（会话亲和）

### 4.1 基于 ClientIP 的亲和性

Kubernetes 支持基于客户端 IP 的会话亲和：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: ClusterIP
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800 # 3 小时超时
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

### 4.2 Maglev 一致性哈希

Cilium 使用 **Maglev** 算法实现会话亲和，保证同一源 IP 始终映射到同一后端：

```
原理：
- 创建大小为 M 的查找表（通常 M = 257 或 65537）
- 对每个后端计算 M 个不同的哈希值
- 每个哈希值决定后端在查找表中的位置
- 查找时，对源 IP 计算哈希，直接查表获取后端

优势：
- O(1) 查找复杂度
- 重新分配后端时，扰动最小
- 一致性保证：同一源 IP 总是得到相同结果
```

```c
// 简化 Maglev 哈希实现
static __always_inline __u32
maglev_lookup(struct bpf_map *permutations, __u32 source_ip) {
    // M = 查找表大小
    // h1(source_ip) = 基哈希
    // h2(source_ip) = 偏移量
    for (int i = 0; i < M; i++) {
        __u32 idx = (h1(source_ip) + i * h2(source_ip)) % M;
        __u32 backend_id = bpf_map_lookup_elem(permutations, &idx);
        if (backend_id != 0) {
            return backend_id;  // 找到有效后端
        }
    }
    return 0;
}
```

### 4.3 Session Affinity 超时

```bash
# 默认超时：10800 秒（3 小时）
# Kubernetes 允许配置 timeoutSeconds

# 查看 Service 的 session 亲和配置
kubectl describe svc my-app | grep -A3 "Session Affinity"
# Session Affinity: ClientIP
# Session Affinity Timeout Sec: 10800

# Cilium 在 eBPF 中记录超时时间
# 超时后，该源 IP 的亲和会重新哈希
```

---

## 5. 流量路径详解

### 5.1 同节点 Pod 通信

当两个 Pod 在同一节点，且访问同节点的后端时：

```
┌──────────────────────────────────────────────────────────┐
│                       Node A                              │
│                                                          │
│  Pod A (10.0.1.10)                                       │
│    eth0@if5 ──┐                                          │
│               │                                          │
│               │  veth pair (cilium_vethXXX)              │
│               │                                          │
│    cilium_host ───────┐                                   │
│                      │                                   │
│                      │      TC Ingress Hook               │
│                      │      (eBPF 策略检查)               │
│                      │                                   │
│                      ▼                                   │
│               ┌─────────────────┐                        │
│               │ cilium_services │ ← O(1) 查找 ClusterIP │
│               └─────────────────┘                        │
│                      │                                   │
│                      │ DNAT (10.96.0.100 → 10.0.1.20)   │
│                      │                                   │
│                      ▼                                   │
│               查找本地 Endpoint                          │
│               (cilium_endpoints)                        │
│                      │                                   │
│                      ▼                                   │
│    eth0@if6 ─────────┤  Pod B (10.0.1.20)                 │
│                     │  (Backend)                         │
└─────────────────────┴────────────────────────────────────┘
```

### 5.2 跨节点 Pod 通信

当后端 Pod 在不同节点时：

```
Pod A (Node A)                    Node B
    │                               │
    │ 访问 ClusterIP: 10.96.0.100   │
    │                               │
    ▼                               │
┌─────────────┐                     │
│ eBPF (TC)   │                     │
│ DNAT 后发现  │                     │
│ 后端不在本地 │                     │
└─────────────┘                     │
    │                               │
    │ 封装VXLAN                     │
    │ 或 直接路由                    │
    ▼                               │
┌─────────────────────────────────┐ │
│         Overlay/VXLAN           │ │
└─────────────────────────────────┘ │
    │                               │
    ▼                               ▼
┌─────────────┐               ┌─────────────┐
│   Node B    │               │  Pod B      │
│  TC Ingress │ ←─────────────│  (Backend)  │
│  接收 VXLAN │               └─────────────┘
└─────────────┘
```

### 5.3 全路径时序图

```
Client Pod          Node A eBPF         VXLAN Tunnel        Node B eBPF        Backend Pod
   │                     │                    │                   │                 │
   │  TCP SYN            │                    │                   │                 │
   │ ───────────────────►│                    │                   │                 │
   │                     │                    │                   │                 │
   │                     │ TC Ingress Hook    │                   │                 │
   │                     │ 提取 dst=ClusterIP │                   │                 │
   │                     │ 查找 eBPF Map      │                   │                 │
   │                     │ ───────────────────│                   │                 │
   │                     │                    │                   │                 │
   │                     │ DNAT(ClusterIP→BIP)│                   │                 │
   │                     │ 生成隧道包          │                   │                 │
   │                     │ ─────────────────────────────────────►│                 │
   │                     │                    │                   │                 │
   │                     │                    │     TC Ingress    │                 │
   │                     │                    │     Decap VXLAN   │                 │
   │                     │                    │     DNAT(BIP→PIP) │                 │
   │                     │                    │     ──────────────►│
   │                     │                    │                   │                 │
   │                     │                    │                   │   TCP SYN       │
   │                     │                    │                   │ ───────────────►│
   │                     │                    │                   │                 │
   │                     │                    │                   │   TCP SYN-ACK   │
   │                     │                    │                   │ ◄───────────────│
   │                     │                    │                   │                 │
   │                     │                    │     封装 VXLAN     │                 │
   │                     │◄─────────────────────────────────────│                 │
   │                     │                    │                   │                 │
   │  TCP SYN-ACK        │                    │                   │                 │
   │ ◄───────────────────│                    │                   │                 │
```

---

## 6. 验证与排错

### 6.1 查看 ClusterIP Service 列表

```bash
# 通过 Cilium CLI 查看所有 Service
kubectl -n kube-system exec ds/cilium -- cilium service list

# 输出示例：
# ID   Frontend             Type      Backend               Source
# 1    10.96.0.1:53         ClusterIP 1 (1 active)         k8s
# 2    10.96.0.100:80       ClusterIP 2 (2 active)         k8s
# 3    10.96.0.100:443      ClusterIP 3 (1 active)         k8s
```

### 6.2 查看 eBPF Service Map 详情

```bash
# 查看 LB eBPF Map 内容
kubectl -n kube-system exec ds/cilium -- cilium bpf lb list

# 更详细的 Map 转储
kubectl -n kube-system exec ds/cilium -- cilium bpf lb dump

# 查看特定 ClusterIP 的后端
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf lb list | grep "10.96.0.100"
```

### 6.3 查看 Backend 状态

```bash
# 查看所有后端
kubectl -n kube-system exec ds/cilium -- cilium bpf backend list

# 输出示例：
# BACKEND ID   ADDRESS         PORT    PROTOCOL   STATE
# 1             10.0.1.20       8080    TCP        active
# 2             10.0.1.21       8080    TCP        active
# 3             10.0.2.20       8080    TCP        terminating
```

### 6.4 调试 ClusterIP 连通性

```bash
# 1. 创建调试 Pod
kubectl run debug --image=busybox --restart=Never --rm -it -- sh

# 2. 在调试 Pod 内测试 ClusterIP 连通性
wget -q -O- http://10.96.0.100:80

# 3. 检查 DNS 解析
nslookup my-app.default.svc.cluster.local

# 4. 使用 ip route 查看路由
ip route get 10.96.0.100

# 5. 抓包分析（eBPF 层面）
kubectl -n kube-system exec ds/cilium -- \
    cilium monitor --type l7 -v
```

### 6.5 常见问题与解决

| 问题                  | 原因                   | 解决方法                                |
| :-------------------- | :--------------------- | :-------------------------------------- |
| ClusterIP 无法访问    | kube-proxy 未禁用/冲突 | 确保 `kubeProxyReplacement=strict`      |
| 后端 Pod 无法接收流量 | Endpoint 不存在        | 检查 Pod label 与 Service selector 匹配 |
| 流量到错误后端        | Session Affinity 过期  | 检查 affinity timeout 配置              |
| 部分节点不通          | eBPF Map 未同步        | 重启该节点的 cilium-agent               |

---

## 7. 章节总结

|                    | 主题                             | 关键点                    |
| :----------------- | :------------------------------- | :------------------------ |
| **ClusterIP 原理** | eBPF Map 替代 iptables           | O(1) 查找，绕过内核协议栈 |
| **Service 映射**   | cilium_services + cilium_backend | LPM Map 支持范围存储      |
| **负载均衡**       | RR/LC/DSR/Maglev                 | 可配置算法，适应不同场景  |
| **Session 亲和**   | Maglev 一致性哈希                | O(1) 查找，支持超时配置   |
| **跨节点通信**     | VXLAN/直接路由                   | 自动选择最优路径          |

**核心优势**：

- **性能**：O(1) 查找 vs iptables O(n) 遍历
- **扩展性**：支持百万级 Service/Endpoint
- **一致性**：Maglev 算法保证会话稳定
- **可观测性**：Hubble 可视化流量路径

**下一章**：NodePort——Cilium 如何通过 XDP 实现高性能的 NodePort 外部访问。

---

## 参考资料

- [Cilium Service Load Balancing](https://docs.cilium.io/en/stable/concepts/services/)
- [Cilium BFP LB Documentation](https://docs.cilium.io/en/stable/reference/bpf/#load-balancing)
- [Maglev: A Fast and Reliable Software Network Load Balancer](https://research.google.com/pubs/archive/44824.pdf)
- [Kubernetes Service Documentation](https://kubernetes.io/docs/concepts/services-networking/service/)
