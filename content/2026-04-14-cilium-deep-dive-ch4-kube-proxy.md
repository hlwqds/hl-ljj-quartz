---
title: "Cilium 深度探索 (4)：Kube-Proxy 替代"
date: 2026-04-14
tags:
  - cilium
  - kube-proxy
  - ebpf
  - service
  - load-balancer
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. **第四章：Kube-Proxy 替代** ←
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]

---

## 1. kube-proxy 的工作原理与瓶颈

### 1.1 kube-proxy 的三种模式

kube-proxy 是 Kubernetes 的核心组件，负责实现 **Service** 的负载均衡。它有三种实现模式：

| 模式          | 原理        | 优点                         | 缺点                      |
| :------------ | :---------- | :--------------------------- | :------------------------ |
| **iptables**  | 规则链匹配  | 成熟稳定                     | 规则多时性能差，O(n) 查找 |
| **ipvs**      | IPVS 哈希表 | 比 iptables 快，支持更多算法 | 需要额外内核模块          |
| **userspace** | 用户态代理  | 灵活                         | 性能最差，已废弃          |

### 1.2 iptables 模式的性能问题

在 iptables 模式下，每个 Service 的每个 Port 都需要在 `nat` 表中创建规则：

```
# 查看一个中等规模集群的 iptables 规则数量
iptables -L -n -t nat | wc -l
# 典型值：5000+ 条规则（100 个 Service × 5 条规则/Service）

# 查看 nat 表大小
iptables -t nat -L -n | head -50
# KUBE-SERVICES
# KUBE-NODEPORTS
# KUBE-POSTROUTING
# KUBE-MARK-MASQ
# KUBE-SVC-XXXX → KUBE-SEP-XXXX (每个 Service 后端一条)
```

当集群规模增长时：

| 集群规模              | Service 数 | iptables 规则数 | 更新延迟 | 内存占用 |
| :-------------------- | :--------- | :-------------- | :------- | :------- |
| 小型（< 50 节点）     | ~200       | ~5,000          | < 100ms  | ~10MB    |
| 中型（50-200 节点）   | ~2,000     | ~50,000         | ~1s      | ~50MB    |
| 大型（200-500 节点）  | ~10,000    | ~250,000        | ~10s     | ~250MB   |
| 超大规模（500+ 节点） | ~50,000    | ~1,250,000      | > 60s    | > 1GB    |

**更新一条 iptables 规则意味着重写整条链**，在大规模集群中会导致**服务中断**（conntrack 条目失效）。

### 1.3 kube-proxy 的工作流程

```
外部流量 → NodePort → kube-proxy → Service IP (SNAT) → Endpoint

1. 包到达 NodePort
2. iptables nat 表匹配 KUBE-NODEPORTS 链
3. 查找 KUBE-SVC-XXXX 链（随机/轮询算法）
4. 找到 KUBE-SEP-XXXX（DNAT，替换目标 IP）
5. 发送到实际 Pod IP
6. 返回时执行反向 SNAT
```

---

## 2. Cilium 如何替代 kube-proxy

### 2.1 核心思想：用 eBPF Map 替代 iptables 链

Cilium 将 Service 的**路由信息存储在 eBPF Map 中**，查找复杂度从 O(n) 降为 **O(1)**：

```
kube-proxy 路径：
  包到达 → 遍历 iptables 链（n 条规则）→ 匹配 → 执行 NAT → 转发

Cilium 路径：
  包到达 → eBPF Map 查找（1 次哈希）→ 执行 NAT → 转发
```

### 2.2 kubeProxyReplacement 配置

Cilium 通过 `kubeProxyReplacement` 配置项控制 kube-proxy 替代的程度：

```bash
# kubeProxyReplacement 选项

# 禁用（默认）：不替代 kube-proxy
kubeProxyReplacement: disabled

# 探测模式：自动检测 kube-proxy 是否存在
kubeProxyReplacement: probe

# 宽松模式：部分替代，缺失功能回退到 kube-proxy
kubeProxyReplacement: partial

# 严格模式：完全替代 kube-proxy（生产推荐）
kubeProxyReplacement: strict
```

**严格模式要求**：

- 集群中没有运行 kube-proxy（或者已删除）
- Cilium 能够正确处理所有 Service 类型

```bash
# 在安装时启用严格模式
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set ebpF.loadBalancer.mode=hybrid
```

---

## 3. eBPF Service 映射原理

### 3.1 cilium_services Map

Cilium 使用 `cilium_services` 这个 **eBPF Map** 存储所有 Service 的后端信息：

```c
// Service Key：唯一确定一个 Service
struct cilium_service_key {
    __u32 addr;        // Service IP (大端序)
    __u16 port;        // Service Port (大端序)
    __u8  proto;       // 协议：TCP(6) / UDP(17)
    __u8  pad;         // 对齐填充
};

// Service Value：后端列表
struct cilium_service_value {
    __u32 backend_count;           // 后端数量
    __u32 backend_ids[16];         // 后端 ID 列表（最多 16 个）
    __u32 flags;                   // 标志：本地优先、session 亲和等
    __u32 src_range[2];            // 源 IP 范围限制
};
```

### 3.2 Backend 存储

后端信息单独存储在 `cilium_backend` Map 中：

```c
struct cilium_backend {
    __u32 addr;         // Pod IP
    __u16 port;         // Pod Port
    __u8  proto;        // 协议
    __u8 flags;         // 标志：active / terminating / idle
    __u32 refcount;     // 引用计数
};
```

### 3.3 Service 查找流程

```
1. 数据包到达 TC Ingress Hook
2. 提取目标 IP + Port + Protocol
3. 构造 cilium_service_key
4. 调用 bpf_map_lookup_elem(&cilium_services, &key)
5. 获取后端列表
6. 根据负载均衡算法选择一个后端
7. 执行 DNAT：Service IP → Backend IP
8. 转发到后端
```

### 3.4 负载均衡算法

Cilium 支持多种负载均衡算法：

| 算法                            | 说明                          | 适用场景           |
| :------------------------------ | :---------------------------- | :----------------- |
| **RR（Round Robin）**           | 轮询所有后端                  | 默认，简单公平     |
| **LC（Least Connected）**       | 选择连接数最少的后端          | 长连接场景         |
| **DSR（Direct Server Return）** | 后端直接返回客户端，无需 SNAT | 高性能场景         |
| **Maglev**                      | 一致性哈希，连接保持          | 需要会话亲和的场景 |

```bash
# 查看当前 Service 的负载均衡配置
kubectl get ciliumendpoints -A -o wide

# 查看某个 Service 的后端分布
kubectl -n kube-system exec ds/cilium -- \
    cilium service list
```

---

## 4. 四种 Service 类型的实现

### 4.1 ClusterIP

ClusterIP 是 Kubernetes Service 的核心类型，Cilium 通过 eBPF 完全替代实现：

```
Pod A → 访问 Service IP (10.96.0.1) → eBPF 查找 → 转发到 Backend Pod

# 不再经过 iptables：
# -iptables -t nat -A KUBE-SVC-XXXX ...  (不再需要)
```

```bash
# 对比：kube-proxy 模式下
iptables -t nat -L KUBE-SVC-NWPXXX -n --line-numbers

# Cilium 模式下：直接查看 eBPF Map
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf lb dump | grep "10.96.0.1"
```

### 4.2 NodePort

NodePort 允许通过 `NodeIP:NodePort` 从集群外部访问 Service。Cilium 在 **XDP 层**实现 NodePort，无需经过内核协议栈：

```bash
# kube-proxy NodePort 路径：
# 物理网卡 → 内核协议栈 → iptables → kube-proxy → Pod

# Cilium NodePort 路径（XDP）：
# 物理网卡 → XDP 程序 → 直接重定向到 Pod（绕过协议栈）
```

**XDP DSR（Direct Server Return）**：

```
外部客户端 → NodePort（XDP 处理）→ Pod → 直接响应客户端
                                    ↑
                             （不使用 SNAT）
```

优势：

- XDP 在 skb 分配前就处理包，节省 CPU
- 后端 Pod 直接返回，不经过中转
- 吞吐量大幅提升

```bash
# 查看 NodePort backend 配置
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf lb list | grep "0.0.0.0:"
# Frontend           Backend
# 0.0.0.0:30080       10.0.0.1:8080 (active)
#                    10.0.0.2:8080 (active)
```

### 4.3 LoadBalancer

LoadBalancer 类型需要云厂商支持，Cilium 与云厂商的 LB 插件集成：

```yaml
# LoadBalancer Service 示例
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```

**Cilium 的 LoadBalancer 实现**：

```
外部 LB → Cilium NodePort → eBPF DSR → Pod
              ↑
         XDP 处理
```

```bash
# 启用 LoadBalancer 模式
helm install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=strict \
    --set loadBalancer.algorithm=least_connections \
    --set bpf.lb.externallb=true
```

### 4.4 ExternalIP

ExternalIP 是绑定到节点网卡上的 IP，作为 Service 的访问入口：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  externalIPs:
    - 192.168.1.100
  ports:
    - port: 80
      targetPort: 8080
```

Cilium 通过 `sk_lookup` eBPF hook 处理 ExternalIP，直接在连接建立时重定向到后端 Pod。

---

## 5. Session 亲和性（Session Affinity）

### 5.1 基于 ClientIP 的亲和性

对于无 Cookie 的服务，Kubernetes 支持基于 `ClientIP` 的会话亲和：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

### 5.2 Cilium 的实现

Cilium 通过 **Maglev 一致性哈希** 实现会话亲和：

```c
// cilium/bpf/lib/lb.h - Maglev 哈希实现
static __always_inline __u32
maglev_hash(__u32 src_ip, __u16 src_port) {
    // Cilium 使用改进的 Maglev 算法
    // 查找表大小 = 辛普森参数 M（通常 257 或 65537）
    // 每次查找只需要 O(1) 步，而非遍历
    return src_ip % M;  // 简化描述
}
```

**与 iptables 的区别**：

| 特性         | kube-proxy (iptables)   | Cilium              |
| :----------- | :---------------------- | :------------------ |
| Session 亲和 | iptables statistic 模块 | Maglev 哈希         |
| 亲和超时     | 支持                    | 支持                |
| 一致性       | 重新加载时可能丢失      | Maglev 保证查找稳定 |

```bash
# 查看 Service session 亲和配置
kubectl describe svc my-app | grep -A5 "Session Affinity"
```

---

## 6. Headless Service

Headless Service（`clusterIP: None`）不分配 ClusterIP，Cilium 处理方式不同：

```
DNS 查询 → 返回所有后端 Pod IP（而非单个 VIP）
        ↓
客户端直接连接后端 Pod（绕过 Service 层）
```

Cilium 通过 `cilium_endpoints` Map 快速返回后端列表：

```bash
# 查看 Headless Service 的 Endpoint
kubectl get svc my-headless -o jsonpath='{.spec.clusterIP}'
# None

# DNS 查询返回所有 Pod IP
dig my-headless.default.svc.cluster.local
# my-headless.default.svc.cluster.local. 5 IN A 10.0.0.1
# my-headless.default.svc.cluster.local. 5 IN A 10.0.0.2
```

---

## 7. 性能对比

### 7.1 基准测试结果

| 指标                 | kube-proxy (iptables) | Cilium (eBPF) | 提升    |
| :------------------- | :-------------------- | :------------ | :------ |
| Service 查找延迟     | O(n)，n=规则数        | O(1)          | 10-100x |
| 每秒新建连接数       | ~5,000                | ~50,000+      | 10x     |
| 最大 Service 数      | ~10,000               | 无硬限制      | 50x+    |
| 规则更新延迟         | >1s（大规模）         | <1ms          | 1000x   |
| NodePort 吞吐量      | ~500 Kpps             | ~2,000+ Kpps  | 4x      |
| CPU 使用（5000 Svc） | ~30% 单核             | ~5% 单核      | 6x      |

### 7.2 验证 Cilium Service

```bash
# 1. 检查 kube-proxy 是否已移除
kubectl get pods -n kube-system -l k8s-app=kube-proxy
# 应该返回空或不存在

# 2. 检查 Cilium Service 状态
kubectl -n kube-system exec ds/cilium -- cilium service list

# 3. 创建测试 Service 并验证
kubectl create deployment nginx --image=nginx
kubectl expose deployment nginx --port=80 --type=ClusterIP

# 4. 验证 eBPF 路径
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf lb list | grep nginx

# 5. 测试连接
kubectl run client --image=busybox --restart=Never -- \
    wget -q -O- http://nginx.default.svc.cluster.local
```

---

## 8. 章节总结

| 功能              | kube-proxy                                    | Cilium            |
| :---------------- | :-------------------------------------------- | :---------------- |
| **Service 类型**  | ClusterIP, NodePort, LoadBalancer, ExternalIP | 全部支持          |
| **查找复杂度**    | O(n) iptables 遍历                            | O(1) eBPF Map     |
| **NodePort 处理** | iptables + 内核协议栈                         | XDP（绕过协议栈） |
| **Session 亲和**  | iptables statistic                            | Maglev 一致性哈希 |
| **DSR 支持**      | 需要额外配置                                  | 原生支持          |
| **最大规模**      | ~10,000 Service                               | 百万级 Endpoint   |

**下一章**：CNI 集成——Cilium 如何与 Kubernetes 网络生态系统中的其他组件配合工作。

---

## 参考资料

- [Cilium Kube-proxy Replacement](https://docs.cilium.io/en/stable/gettingstarted/kubeproxy-free/)
- [Cilium Service Load Balancing](https://docs.cilium.io/en/stable/concepts/services/)
- [Cilium bpf lb](https://docs.cilium.io/en/stable/reference/cli/cilium_bpf_lb/)
- [Linux Kernel Networking: Service Load Balancing](https://www.kernel.org/doc/html/latest/networking/kcontrol-bsp)
