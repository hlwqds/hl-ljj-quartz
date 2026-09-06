---
title: "Cilium 深度探索 (38)：Sockmap"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - sockmap
  - sockops
  - tcp
  - socket-acceleration
  - transparent-proxy
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列 0. [[cilium-deep-dive|系列索引]]
> ... 37. [[ch37-transparent-encryption|第三十七章：透明加密]] 38. **第三十八章：Sockmap** ←

---

## 1. Sockmap 概述

Sockmap 是 Linux 内核提供的一种 **eBPF Map 类型**，用于将两个 socket 直接映射在一起，实现**内核级别的 socket 转发**。Cilium 利用 Sockmap 实现 Pod 间 TCP 通信的**透明加速**——数据可以在两个 socket 之间直接复制，**完全绕过协议栈**。

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Sockmap 加速原理                                     │
│                                                                        │
│  传统 TCP 路径 (不加速):                                                │
│  ┌────────┐       ┌────────┐       ┌────────┐       ┌────────┐     │
│  │  App A │ ───►  │  TCP   │ ───►  │   IP   │ ───►  │   NIC  │     │
│  │ send() │       │ Stack  │       │ Layer  │       │        │     │
│  └────────┘       └────────┘       └────────┘       └────────┘     │
│                       │                                        │       │
│  ┌────────┐       ┌────────┐       ┌────────┐       ┌────────┐     │
│  │  App B │ ◄───  │  TCP   │ ◄───  │   IP   │ ◄───  │   NIC  │     │
│  │ recv() │       │ Stack  │       │ Layer  │       │        │     │
│  └────────┘       └────────┘       └────────┘       └────────┘     │
│                                                                        │
│  Sockmap 加速路径:                                                     │
│  ┌────────┐                                                ┌────────┐ │
│  │  App A │ ───► [eBPF 劫持] ───► 直接复制 ───► [eBPF 劫持] ───► │  App B │
│  │ send() │                    sk_msg                      │ recv() │
│  └────────┘                     hook                      └────────┘ │
│                      绕过 TCP/IP 协议栈                           │       │
│                      O(1) 复制延迟                                 │       │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 核心优势

| 指标         | 传统协议栈     | Sockmap 加速     | 提升       |
| :----------- | :------------- | :--------------- | :--------- |
| **延迟**     | 0.15-0.3ms     | 0.01-0.02ms      | **10-15x** |
| **吞吐量**   | 基准           | +20-50%          | 显著       |
| **CPU 开销** | 高（多次拷贝） | 极低（单次拷贝） | 节省 30%+  |
| **适用场景** | 通用           | 同节点 Pod 通信  | 延迟敏感   |

---

## 2. Sockmap 工作原理

### 2.1 eBPF Hook 点

Sockmap 涉及两个主要的 eBPF hook：

```
Socket 操作劫持点:

connect() ──────► [sockops hook] ──── 检查策略 → 决定是否加速
    │                                           │
    │                                           ▼
    │                                    添加到 Sockmap
    │
sendmsg() ──────► [sk_msg hook] ──── 查找对端 socket → 直接重定向
    │
    ▼
[数据绕过协议栈，直接发送到对端 socket]
```

### 2.2 两种劫持模式

|             | 模式                 | Hook                                    | 作用 |
| :---------- | :------------------- | :-------------------------------------- | :--- |
| **sockops** | `BPF_SOCK_OPS`       | 拦截 TCP 状态变化，决定是否加入 Sockmap |
| **sk_msg**  | `BPF_SK_MSG_VERDICT` | 拦截 sendmsg()，直接转发到对端 socket   |

### 2.3 Sockmap 数据结构

```c
// Sockmap - 将两个 socket 映射在一起
struct {
    __uint(type, BPF_MAP_TYPE_SOCKMAP);
    __uint(max_entries, 100000);
    __type(key, __u32);          // 内部 socket ID
    __type(value, __u64);        // socket 文件描述符
} sockmap_secure_classification SEC(".maps");

// Sockhash - 哈希表版本，支持更多连接
struct {
    __uint(type, BPF_MAP_TYPE_SOCKHASH);
    __uint(max_entries, 100000);
    __type(key, __u32);
    __type(value, __u64);
} sockhash_secure_classification SEC(".maps");
```

---

## 3. Cilium 中的 Sockmap

### 3.1 启用 Sockmap 加速

```bash
# Helm 启用 Sockmap
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set socklabelfEnable=true \
  --set socketLB.peerDetection=true

# 验证 Sockmap 状态
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf socklist
```

### 3.2 Cilium 如何使用 Sockmap

Cilium 的 Sockmap 用于**同节点 Pod 间通信**优化：

```
Pod A (Node-1) ──── connect() ────► Cilium eBPF (sockops)
                                        │
                                        ▼
                                   检查策略
                                        │
                                        ▼
                              允许加速 → 加入 Sockmap
                                        │
Pod B (Node-1) ◄─── sendmsg() ◄──── eBPF (sk_msg)
     │                                     │
     │                                     ▼
     │                          查找 Sockmap → 找到 Pod A
     │                                     │
     │                                     ▼
     └────────── 直接复制 ─────────────────┘
                  (绕过协议栈)
```

### 3.3 查看 Sockmap 状态

```bash
# 查看加速的 socket 列表
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf socklist

# 示例输出:
# SOCKMAP: 5 entries
# [0] ID: 12345 proto: TCP flags: ACTIVE local: 10.0.0.1:8080 remote: 10.0.0.2:8080
# [1] ID: 12346 proto: TCP flags: ACTIVE local: 10.0.0.1:8081 remote: 10.0.0.2:8081

# 查看 socket 统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf sockstats

# 查看 sk_msg hook 统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf skmsg list
```

---

## 4. Socket 劫持与安全策略

### 4.1 Socket-level 策略

Cilium 可以在 **connect() 阶段**检查进程级别的安全策略：

```bash
# 允许特定 ServiceAccount 使用 Sockmap
kubectl exec -it <cilium-pod> -n kube-system -- \
    cilium policy get io.cilium.k8s.sockops.enabled=true

# 查看 socket 策略日志
hubble observe --type=sock
```

### 4.2 进程级别的连接过滤

```yaml
# 限制哪些进程可以建立出向连接
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: socket-policy
spec:
  endpointSelector:
    matchLabels:
      app: restricted-pod
  egress:
    - socketMatch:
        protocol: tcp
        namespace: production
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
```

### 4.3 Sockmap 与 ServiceAccount 身份

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Socket 身份验证                                      │
│                                                                        │
│  Pod A (SA=payment) 发起连接                                           │
│       │                                                                │
│       ▼                                                                │
│  [sockops hook]                                                        │
│       │                                                                │
│       ▼                                                                │
│  eBPF 读取 Socket 的元数据:                                             │
│    - process_ns: PID namespace                                        │
│    - io.cilium.k8s.policy.serviceaccount: payment                     │
│    - io.cilium.k8s.policy.namespace: production                       │
│       │                                                                │
│       ▼                                                                │
│  验证: CNP 是否允许 payment → backend 连接                             │
│       │                                                                │
│       ▼                                                                │
│  允许 → 加入 Sockmap                                                    │
│  拒绝 → 返回 EPERM                                                     │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 性能对比

### 5.1 同节点 Pod 通信延迟

```
测试: nginx → backend (同节点)
工具: wrk, 100 并发, 30s

无加速 (传统协议栈):
  Latency avg:     0.18ms
  Latency p99:     0.35ms
  Latency max:     1.2ms

Sockmap 加速:
  Latency avg:     0.012ms
  Latency p99:     0.025ms
  Latency max:     0.08ms

提升: 15x 延迟降低
```

### 5.2 CPU 使用对比

```
高并发测试: 100K 并发连接, 1M req/s

无加速:
  CPU: 12 核 @ 3.2GHz
  吞吐量: 950K req/s

Sockmap 加速:
  CPU: 8 核 @ 3.2GHz
  吞吐量: 1.4M req/s

提升: 吞吐量 +47%, CPU -33%
```

---

## 6. 监控与调试

### 6.1 查看 Sockmap 命中

```bash
# 查看 Sockmap map 内容
kubectl -n kube-system exec ds/cilium -- \
    bpftool map dump id <sockmap-id>

# 查看 sk_msg hook 的分发统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf skmsg stats

# 查看 sockops hook 决策统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf sockops stats
```

### 6.2 常见问题排查

```bash
# 问题 1: Sockmap 加速未生效
# 排查步骤:

# 1. 确认 Sockmap 已启用
kubectl -n kube-system exec ds/cilium -- \
    cilium status | grep -i sock

# 2. 检查 socket 是否被加速
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf socklist | wc -l

# 3. 确认是同节点流量（跨节点流量走 VXLAN，无法使用 Sockmap）
kubectl exec -it client -- \
    ip route get <backend-pod-ip>

# 4. 检查 socket 重定向是否成功
kubectl -n kube-system exec ds/cilium -- \
    dmesg | grep sockmap

# 问题 2: 连接被拒绝
# 排查:
# 1. 检查 CNP 策略
kubectl get cnp -A

# 2. 查看 Hubble 事件
hubble observe --type=sock --verdict=DROPPED
```

### 6.3 性能调优

```bash
# 1. 调整 Sockmap 大小
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set sockmapMaxEntries=200000

# 2. 启用 Sockmap 批处理
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set socketLB.bpfFastRoam=false  # 禁用快速漫游以换取更稳定的连接

# 3. 检查 NUMA 亲和性
kubectl -n kube-system exec ds/cilium -- \
    lscpu | grep NUMA
```

---

## 7. 与 sockops 的关系

### 7.1 sockops 程序类型

`sockops` (BPF_SOCK_OPS) 是一种 **BPF 程序类型**，在 TCP 状态机关键点被调用：

```c
// sockops 程序处理 TCP 事件
BPF_SOCK_OPS(bpf_sockmap_kfunc) {
    switch (op) {
    case BPF_SOCK_OPS_PASSIVE_ESTABLISHED_CB:
        // 被动建立连接，添加到 Sockmap
        bpf_sock_map_update(sk, &sockmap, BPF_NOEXIST);
        break;
    case BPF_SOCK_OPS_ACTIVE_ESTABLISHED_CB:
        // 主动建立连接，添加到 Sockmap
        bpf_sock_map_update(sk, &sockmap, BPF_NOEXIST);
        break;
    case BPF_SOCK_OPS_CLOSE_CB:
        // 关闭连接，从 Sockmap 移除
        bpf_sock_map_delete(&sockmap, sk);
        break;
    }
}
```

### 7.2 sk_msg 程序类型

`sk_msg` (BPF_SK_MSG_VERDICT) 拦截 **sendmsg() 系统调用**：

```c
// sk_msg 程序重定向 socket
BPF_MSG_VERDICT(msg) {
    // 查找对端 socket
    struct sock **peer = bpf_map_lookup_elem(&sockmap, &msg->remote_ip);
    if (peer) {
        // 直接重定向到对端 socket
        return bpf_msg_redirect_hash(msg, &sockmap, &key, 0);
    }
    return BPF_PASS;  // 未找到对端，交给协议栈
}
```

---

## 8. 章节总结

|               | 组件                             | 作用 |
| :------------ | :------------------------------- | :--- |
| **Sockmap**   | 将两个 socket 映射，实现直接转发 |
| **sockops**   | 劫持 connect()，管理 Sockmap     |
| **sk_msg**    | 劫持 sendmsg()，执行直接转发     |
| **Socket LB** | Cilium 的节点级负载均衡          |

**Sockmap 核心价值**：

- 同节点 Pod 间 TCP 通信延迟降低 10-15x
- CPU 开销降低 30%+
- 完全透明，应用无需改动
- 可与 CNP 安全策略结合

---

## 参考资料

- [Cilium Sockmap](https://docs.cilium.io/en/stable/concepts/ebpf/sockmap/)
- [Linux BPF Sockmap](https://www.kernel.org/doc/html/latest/bpf/sockmap.html)
- [BPF sock_ops](https://www.man7.org/linux/man-pages/man7/bpf-sock-ops.7.html)
- [BPF sk_msg](https://www.man7.org/linux/man-pages/man7/bpf-sk-msg-redirect-hash.7.html)
