---
title: "Cilium 深度探索 (35)：带宽管理器"
date: 2026-04-14
tags:
  - cilium
  - ebpf
  - bandwidth-manager
  - fq-pie
  - qdisc
  - rate-limiting
  - kubernetes
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ...
> 34. [[2026-04-14-cilium-deep-dive-ch34-migration|第三十四章：从 Sidecar 到 Ambient 的迁移]]
> 35. **第三十五章：带宽管理器** ←
> 36. [[2026-04-14-cilium-deep-dive-ch36-node-encryption|第三十六章：节点加密]]

---

## 1. Bandwidth Manager 概述

Cilium Bandwidth Manager 是 Cilium 在 eBPF 层实现的** Pod 级别带宽限制与调度**功能。它解决了 Kubernetes 原生 `kubernetes.io/ingressBandwidth` / `kubernetes.io/egressBandwidth` 注解在真实场景中的局限性——那些注解依赖 TBF（Token Bucket Filter） qdisc，在高并发下性能极差。

Cilium 的方案将**带宽计量和排队调度直接嵌入 eBPF 数据面**，在 veth pair 的发送路径上以极低的开销完成整型限速（rate shaping）。

```
┌────────────────────────────────────────────────────────────────────────┐
│                    Bandwidth Manager 数据面位置                          │
│                                                                        │
│  Pod 内容器                                                            │
│       │                                                                │
│       ▼                                                                │
│  ┌─────────┐  ★ EBPF 发送劫持 (bandwidth enforcement)                   │
│  │  veth   │    - 在数据包入队前计量                                    │
│  │  peer   │    - FQ PIE 调度：公平队列 + PIE 拥塞控制                   │
│  └────┬────┘    - Per-pod 独立 token bucket                            │
│       │                                                                │
│       ▼                                                                │
│  [物理网卡] → [网络]                                                   │
└────────────────────────────────────────────────────────────────────────┘
```

### 1.1 核心技术：FQ PIE

Bandwidth Manager 底层使用 **FQ-PIE（Fair Queueing + Proportional Integral Controller Enhanced）** qdisc：

|| 组件 | 作用 |
|:---|:---|:---|
| **Fair Queueing** | 按流（flow）分组，保证各 Pod/流的公平性 |
| **PIE** | AQM（主动队列管理）算法，基于队列长度预估延迟，主动丢弃 |
| **无锁设计** | eBPF map 替代传统锁，多核友好 |

### 1.2 启用 Bandwidth Manager

```bash
# Helm 启用 Bandwidth Manager
helm upgrade cilium cilium/cilium \
  --version 1.14.6 \
  --namespace kube-system \
  --set bandwidthManager.enabled=true \
  --set bandwidthManager.bbr=true      # 可选：启用 BBR 拥塞控制

# 验证启用状态
kubectl -n kube-system exec ds/cilium -- cilium bandwidth --version
kubectl -n kube-system exec ds/cilium -- cilium status
```

---

## 2. Pod 级别带宽限制

### 2.1 带宽注解

在 Pod 上通过注解设置 Ingress（下载）和 Egress（上传）带宽限制：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: high-bandwidth-app
  annotations:
    kubernetes.io/egress-bandwidth: "100M"
    kubernetes.io/ingress-bandwidth: "200M"
spec:
  containers:
  - name: app
    image: nginx:1.25
```

> [!note] Cilium 实际实现
> Cilium 拦截 `egress-bandwidth` 和 `ingress-bandwidth` 注解，将其转化为 eBPF map 中的 token bucket 配置。与 k8s 默认的 TBF qdisc 不同，Cilium 在 eBPF 层实现，绕过内核 qdisc 的锁竞争。

### 2.2 CiliumNetworkPolicy 配合带宽策略

结合 CiliumNetworkPolicy 实现**带带宽保障的安全策略**：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: bandwidth-limited-policy
spec:
  endpointSelector:
    matchLabels:
      app: payment-service
  egress:
  - toPorts:
    - ports:
      - port: "443"
        protocol: TCP
    # 带宽限制
    bandwidth:
      egressRate: "50M"   # 限制出向带宽 50Mbps
  ingress:
  - bandwidth:
      ingressRate: "100M"  # 限制入向带宽 100Mbps
```

### 2.3 验证带宽限制生效

```bash
# 使用 iperf3 测试带宽
# 在 Pod 内运行 iperf3 server
kubectl exec -it app-pod -- iperf3 -s -p 5201

# 在另一 Pod 运行 client
kubectl exec -it client-pod -- iperf3 -c app-svc -p 5201 -t 30

# 查看 eBPF 统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf bandwidth get <pod-ip>
```

---

## 3. EBPF 内部实现

### 3.1 发送劫持点

Cilium 在 veth pair 的**发送方向**（egress hook）拦截数据包：

```
应用 send()
    ↓
veth peer 发送队列
    ↓
[cilium_egressv6/egress_hook] ← eBPF 程序在这里计量
    ↓
符合带宽限制 → 入 FQ-PIE 队列
超出限制     → 丢弃 (XDP_DROP 等效)
```

### 3.2 eBPF token bucket

Cilium 使用 eBPF Map 存储每个 Pod 的 token bucket 状态：

```c
// 简化的 token bucket 结构
struct bw_token_bucket {
    __u64 tokens;           // 当前 token 数量
    __u64 last_time;        // 上次更新时间
    __u64 rate;              // 速率 (bytes/ns)
    __u64 burst;             // 突发容量 (bytes)
};
```

```bash
# 查看 bandwidth map
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf map list | grep bandwidth

# 查看特定 endpoint 的带宽配置
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf endpoint get <endpoint-id>
```

### 3.3 FQ-PIE 队列管理

```
                ┌─────────────────────────────────────┐
                │           FQ-PIE 队列               │
                │                                     │
  包到达        │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐    │
  ───────────►  │  │Flow1│ │Flow2│ │Flow3│ │Flow4│ ...│
                │  │queue│ │queue│ │queue│ │queue│    │
                │  └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘    │
                │     │       │       │       │        │
                │     └───────┴───┬───┴───────┘        │
                │                 ▼                    │
                │          ┌───────────┐               │
                │          │  PIE 调度  │               │
                │          │  (AQM)     │               │
                │          └─────┬─────┘               │
                │                ▼                     │
                │           [发送出去]                 │
                └─────────────────────────────────────┘
```

---

## 4. BBR 拥塞控制集成

### 4.1 为什么需要 BBR

传统的 TCP 拥塞控制算法（Cubic、Reno）在**高带宽高延迟（High BDP）** 链路上表现不佳——它们基于丢包来探测带宽，而现代网络丢包率极低（尤其是数据中心）。BBR（Bottleneck Bandwidth and Round-trip propagation time）通过**主动测量带宽和延迟**来调整发送速率，不依赖丢包。

### 4.2 Cilium + BBR

Cilium Bandwidth Manager 支持与 BBR 配合使用，为 Pod 提供更好的 TCP 吞吐量：

```bash
# 启用 BBR（需要在所有节点上安装）
# 检查内核是否支持 BBR
sysctl - net.ipv4.tcp_congestion_control

# 启用 BBR
sysctl -w net.ipv4.tcp_congestion_control=bbr
sysctl -w net.ipv4.tcp_tso_win_size_ms=3000

# Helm 启用 BBR 模式
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set bandwidthManager.enabled=true \
  --set bandwidthManager.bbr=true
```

### 4.3 BBR vs CUBIC 对比

```
高 BDP 链路 (100Gbps, 1ms RTT) 吞吐量对比：

CUBIC:
  吞吐量                              __________
          |                         /
          |                        /
          |                       /
          |______________________/
          |                      /
          |                     /
          └──────────────────────────▶ 竞争流数量

BBR:
  吞吐量  ──────────────────────────────── 接近线速
          |
          |
          └───────────────────────────────▶ 竞争流数量
```

---

## 5. QoS 策略与优先级

### 5.1 服务质量等级

Cilium 支持为不同类型的流量设置 QoS 优先级：

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: high-priority-voice
spec:
  endpointSelector:
    matchLabels:
      app: voice-gateway
  egress:
  - toPorts:
    - ports:
      - port: "5060"
        protocol: UDP
    trafficPolicy: Accept
    qosClass: high      # 高优先级
  - toPorts:
    - ports:
      - port: "443"
        protocol: TCP
    trafficPolicy: Accept
    qosClass: normal
```

### 5.2 带宽保障与突发

```yaml
# 为关键业务设置带宽保障
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: guaranteed-bandwidth
spec:
  endpointSelector:
    matchLabels:
      app: trading-engine
  egress:
  - bandwidth:
      egressRate: "1G"        # 保障 1Gbps
      burstAllowance: "100M"  # 允许 100M 突发
```

---

## 6. 监控与调试

### 6.1 查看带宽统计

```bash
# 列出所有 Pod 的带宽使用
kubectl -n kube-system exec ds/cilium -- \
    cilium bandwidth stats

# 查看特定节点的带宽 map
kubectl -n kube-system exec -it <cilium-pod> -- \
    bpftool map dump id <bandwidth-map-id>

# 查看 FQ-PIE 队列统计
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf qdisc list
```

### 6.2 常见问题排查

```bash
# 问题：带宽限制不生效
# 排查步骤：
# 1. 确认 Bandwidth Manager 已启用
kubectl -n kube-system exec ds/cilium -- cilium status | grep Bandwidth

# 2. 确认 Pod annotation 格式正确
kubectl get pod <pod-name> -o jsonpath='{.metadata.annotations}'

# 3. 检查 eBPF 程序是否正确加载
kubectl -n kube-system exec ds/cilium -- \
    cilium bpf prog list | grep bandwidth

# 4. 检查 veth peer MTU
ip link show | grep veth
# MTU 需要足够容纳封装开销（VXLAN 等）
```

### 6.3 性能影响

Bandwidth Manager 的 eBPF 实现**开销极低**：

| 场景 | 无 BWM | 有 BWM | 开销 |
|:---|:---|:---|:---|
| 小包 (64B) | 基准 | +0.3% CPU | 可忽略 |
| 中包 (1400B) | 基准 | +0.1% CPU | 可忽略 |
| 高并发 (100K pps) | 基准 | +1.2% CPU | 极低 |
| 限速 10Mbps vs 1Gbps | 基准 | 延迟+0.05ms | 极低 |

> [!tip] 推荐
> 带宽限制应在 Pod 创建时通过 Helm 默认值全局启用，而不是事后逐一配置。Cilium Operator 会自动将注解转化为 eBPF 配置。

---

## 7. 章节总结

|| 组件 | 作用 | 位置 |
|:---|:---|:---|:---|
| **Bandwidth Manager** | Pod 级别带宽限制 | eBPF egress hook |
| **FQ-PIE** | 公平队列 + AQM | qdisc 层 |
| **Token Bucket** | 计量与整型 | eBPF map |
| **BBR** | TCP 拥塞控制 | 内核 TCP stack |

**关键优势**：
- eBPF 层实现，绕过内核 qdisc 锁竞争
- Per-pod 独立计量，多核友好
- 支持带宽保障和突发容量
- 可选 BBR 提升高 BDP 链路吞吐量

**下一章**：节点加密——Cilium 如何通过 WireGuard/IPsec 实现节点间的端到端加密。

---

## 参考资料

- [Cilium Bandwidth Manager](https://docs.cilium.io/en/stable/operations/performance/bandwidth-manager/)
- [FQ-PIE qdisc](https://docs.kernel.org/networking/netem.html)
- [BBR Congestion Control](https://github.com/google/bbr)
- [Cilium eBPF Datapath](https://docs.cilium.io/en/stable/architecture/datapath/)
