---
title: "Cilium 深度探索 (42)：性能调优与基准测试"
date: 2026-04-14
tags:
  - cilium
  - performance
  - benchmarking
  - tuning
  - ebpf
  - latency
  - throughput
  - operations
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> ... 38. [[2026-04-14-cilium-deep-dive-ch38-sockmap|第三十八章：Sockmap]] 39. [[2026-04-14-cilium-deep-dive-ch39-install|第三十九章：生产级安装指南]] 40. [[2026-04-14-cilium-deep-dive-ch40-upgrade|第四十章：升级策略]] 41. [[2026-04-14-cilium-deep-dive-ch41-debug|第四十一章：故障诊断]] 42. **第四十二章：性能调优与基准测试** ←

---

## 1. 性能架构概述

Cilium 的性能取决于多个层面的优化，从内核 eBPF 运行引擎到用户空间 Agent，每个环节都有调优空间。

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Cilium 性能层次                                   │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   应用层                                                              │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │  Pod → Socket → eBPF (sockmap/sockhash) → 直接转发          │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│   eBPF 数据面                                                         │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │  XDP (最早处理点) → TC (Ingress/Egress) → Host Routing      │   │
│   │  ├── 无拷贝 (zero-copy)                                       │   │
│   │  ├── 无分配 (no allocation)                                   │   │
│   │  └── 本地优先 (local-first)                                   │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│   负载均衡                                                            │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │  MagLev/Weighted-Round-Robin → LRU → DSR/SNAT               │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│   加密层 (可选)                                                        │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │  WireGuard (内核 5.6+) / IPsec (hw offload)                 │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.1 性能关键指标

| 指标         | 典型值     | 说明            |
| :----------- | :--------- | :-------------- |
| **P99 延迟** | 10-50 µs   | Pod-to-Pod 延迟 |
| **吞吐量**   | 10-40 Gbps | 单链路          |
| **CPS**      | 100K-500K  | 每秒新建连接数  |
| **PPS**      | 1-5 Mpps   | 每秒数据包数    |
| **CPU 开销** | 1-5%       | Agent 平均 CPU  |

---

## 2. eBPF 性能配置

### 2.1 主机路由 (Host Routing)

启用主机路由可避免包经过网络命名空间，实现内核直通：

```yaml
# cilium-values.yaml
bpf:
  hostRouting: true # 需要内核 5.10+
  # 启用后，本地流量直接路由，不经过额外处理
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Host Routing vs 传统路由                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   传统路由模式                                                        │
│   ─────────────                                                      │
│   Pod → eth0 → namespace switch → eth0 → Pod                        │
│   (额外的网络命名空间切换)                                             │
│                                                                     │
│   Host Routing 模式                                                  │
│   ─────────────────                                                  │
│   Pod → eth0 → 直接路由 → eth0 → Pod                                │
│   (内核直连，零额外跳转)                                               │
│                                                                     │
│   性能提升: 30-50% 延迟降低                                            │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 2.2 XDP 加速

XDP (eXpress Data Path) 在网卡驱动层处理包，实现最高性能：

```yaml
# 启用 XDP 加速
loadBalancer:
  acceleration: always # always | opt-in | disabled

# XDP 模式选择
xdp:
  mode: adaptive # native | generic | redirect | adaptive
```

| XDP 模式     | 性能     | 兼容性       |
| :----------- | :------- | :----------- |
| **native**   | 最高     | 需要驱动支持 |
| **generic**  | 中等     | 所有驱动     |
| **redirect** | 最高     | 智能网卡     |
| **adaptive** | 自动选择 | 推荐         |

### 2.3 BPF Map 大小调优

根据集群规模调整 Map 大小：

```yaml
bpf:
  # Service Map
  mapDynamicSockRecords: 65536

  # NAT Map
  natMapMaxEntries: 65536

  # Conntrack Map
  ctMapMaxEntries: 65536

# 动态调整示例
# small cluster (< 100 nodes): 65536
# medium cluster (100-500): 262144
# large cluster (> 500): 1048576
```

### 2.4 LRU 缓存优化

```yaml
# 启用 LRU 缓存减少全局锁竞争
bpf:
  lbExternalAddressIPPort: true
  lbL7: true

loadBalancer:
  # LRU Map 大小
  lruMapSize: 65536
  # LRU 亲和
  lruLocalAffinity: true
```

---

## 3. 负载均衡器调优

### 3.1 调度算法选择

```yaml
loadBalancer:
  algorithm: MagLev # maglev | round_robin | weighted_round_robin | random
```

| 算法                     | 特点                 | 适用场景     |
| :----------------------- | :------------------- | :----------- |
| **MagLev**               | 一致性哈希，连接稳定 | 长连接服务   |
| **Weighted Round Robin** | 权重轮询             | 异构后端     |
| **Round Robin**          | 简单轮询             | 无状态服务   |
| **Random**               | 随机选择             | 负载均衡测试 |

### 3.2 DSR vs SNAT

```
┌─────────────────────────────────────────────────────────────────────┐
│                    DSR vs SNAT 模式                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   DSR (Direct Server Return)                                        │
│   ───────────────────────────                                       │
│   请求: Client → Node1 → Pod                                        │
│   响应: Pod → Node1 → Client (直接返回，不经过 Node1)                 │
│                                                                     │
│   优势: 响应延迟 低，吞吐量 高                                         │
│   适用: 流量不对称场景 (响应 > 请求)                                   │
│                                                                     │
│   SNAT (Source Network Address Translation)                         │
│   ───────────────────────────────────────                           │
│   请求: Client → Node1 → Pod                                        │
│   响应: Pod → Node1 → SNAT → Client                                 │
│                                                                     │
│   优势: 简单，兼容性 好                                              │
│   适用: 需要隐藏后端 IP                                              │
│                                                                     │
│   Hybrid (推荐)                                                      │
│   ────────────────                                                  │
│   自动选择: DSR 用于本地后端，SNAT 用于远程后端                       │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

```yaml
loadBalancer:
  mode: hybrid # snat | dsr | hybrid
```

### 3.3 MagLev 一致性哈希

```yaml
# 启用 MagLev 查找表
loadBalancer:
  algorithm: maglev
  # MagLev 表大小 (必须是质数)
  maglevTableSize: 65537
  # 或更大的表提升命中率
  # maglevTableSize: 16777213
```

---

## 4. 带宽管理器

### 4.1 EDT (Earliest Departure Time)

EDT 通过控制包发送时间实现精准限速：

```yaml
bandwidth-manager:
  enabled: true
  # 需要内核 5.18+ 支持
  # bbr: true  # BBR 拥塞控制
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                    EDT vs 传统 Token Bucket                         │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   Token Bucket (传统)                                                │
│   ─────────────────                                                 │
│   发送速率: 突发 → 限制 → 突发 → 限制                                │
│   问题: 突发造成排队延迟                                              │
│                                                                     │
│   EDT (Earliest Departure Time)                                     │
│   ──────────────────────────────────                                │
│   发送时间: 预先计算，严格按时间发送                                   │
│   优势: 延迟稳定，无突发排队                                          │
│                                                                     │
│   适合: 视频/音频/实时应用                                             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 Pod 带宽限制

```yaml
# 在 CiliumNetworkPolicy 中限制 Pod 带宽
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: rate-limit
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  egress:
    - toPorts:
        - ports:
            - port: "80"
              protocol: TCP
      bandwidth:
        egress:
          rate: 100Mbps # 限速 100Mbps
```

---

## 5. Socket 优化

### 5.1 Sockmap 加速

Sockmap 允许 eBPF 直接在 Socket 层加速，避免穿越协议栈：

```yaml
# 启用 sockmap
bpf:
  sockmap: true
  # 启用后，同一节点内的 Pod 通信直接通过 Socket 转发
```

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Sockmap 加速原理                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   无 Sockmap:                                                        │
│   Pod A → eth0 → TCP Stack → eth0 → Pod B                            │
│   (经过完整 TCP/IP 协议栈)                                            │
│                                                                     │
│   有 Sockmap:                                                        │
│   Pod A → Socket → Socket → Pod B                                    │
│   (跳过协议栈，直接转发)                                               │
│                                                                     │
│   性能提升: 2-3x 吞吐量，显著降低延迟                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 5.2 Socket 传递

```yaml
# 启用 Socket 传递（同一连接跨节点迁移）
bpf:
  sockpush: true
```

---

## 6. 延迟优化

### 6.1 关键延迟来源

| 阶段             | 延迟 (µs) | 优化方式     |
| :--------------- | :-------- | :----------- |
| XDP 处理         | 1-2       | Native XDP   |
| eBPF 转发        | 2-5       | Host Routing |
| Service 查找     | 5-10      | LRU 缓存     |
| Conntrack        | 5-15      | 禁用（可选） |
| NAT              | 10-20     | DSR 模式     |
| 加密 (WireGuard) | 50-200    | 硬件卸载     |

### 6.2 减少延迟的配置

```yaml
# 低延迟配置
bpf:
  hostRouting: true
  clockProbe: false # 禁用时钟探测
  fragments-map-max-entries: 4096

loadBalancer:
  mode: dsr # 直接返回

# 禁用不必要的功能
enable:
  mascara: false # 禁用 masquerade
  pop/pop: false # 禁用 port preservation
```

### 6.3 NAPI 和gro_batch

```bash
# 启用 GRO 批量处理
ethtool -K cilium+ gro on

# 查看 NAPI 权重
cat /proc/sys/net/core/netdev_budget

# 调整 NAPI 权重提升吞吐
sysctl -w net.core.netdev_budget=600
```

---

## 7. 吞吐量优化

### 7.1 多队列和 RSS

```bash
# 查看网卡队列
ethtool -l cilium+

# 启用多队列
ethtool -L cilium+ combined 8

# 配置 RSS
ethtool -X cilium+ equal 8
```

### 7.2 巨帧 (Jumbo Frames)

```bash
# 启用巨帧 (MTU 9000)
ip link set cilium+ mtu 9000

# 在 values 中配置
# bpf:
#   mtu: 9000
```

### 7.3 TSO/GRO 优化

```bash
# 启用 TSO (TCP Segmentation Offload)
ethtool -K cilium+ tso on

# 启用 GRO (Generic Receive Offload)
ethtool -K cilium+ gro on

# 启用 GSO (Generic Segmentation Offload)
ethtool -K cilium+ gso on
```

---

## 8. CPU 优化

### 8.1 CPU 亲和

```yaml
# Agent CPU 亲和
agent:
  cpuAffinity: "0-7" # 固定到特定 CPU


# 使用 kubelet 隔离的 CPU
# 需要配合 kubelet --cpu-manager policy=static
```

### 8.2 eBPF 编译优化

```bash
# 检查 JIT 编译
cat /proc/sys/net/core/bpf_jit_enable
# 1 = JIT 启用

# 检查 JIT 硬编译
cat /proc/sys/net/core/bpf_jit_harden
# 0 = 关闭 (性能优先)
# 2 = 开启 (安全优先，略微降低性能)

# 生产环境可关闭 JIT 硬化提升性能
sysctl -w net.core.bpf_jit_harden=0
```

### 8.3 内存优化

```bash
# 检查 eBPF Map 内存使用
cilium bpf map list | awk '{print $1}' | xargs -I {} cilium bpf map dump {} | wc -l

# 调整 BPF Map 大小减少内存占用
# bpf:
#   mapTcp6MaxEntries: 32768
#   mapUdp6MaxEntries: 32768
```

---

## 9. 基准测试

### 9.1 qperf

```bash
# 安装 qperf
apt-get install qperf

# Pod 网络基准测试
kubectl run qperf-server --image=quay.io/cilium/qperf:latest -- ports=19765

# 测试延迟
kubectl exec qperf-client -- qperf -t 10 -m <server-ip> latency

# 测试吞吐量
kubectl exec qperf-client -- qperf -t 10 -m <server-ip> tcp_bw
```

### 9.2 iperf3

```bash
# 部署 iperf3
kubectl run iperf3-server --image=networkstatic/iperf3:latest -- -s

# TCP 吞吐量测试
kubectl exec iperf3-client -- iperf3 -c <server-ip> -t 30 -P 8

# UDP 吞吐量测试
kubectl exec iperf3-client -- iperf3 -c <server-ip> -u -t 30 -b 10G
```

### 9.3 基准测试脚本

```bash
#!/bin/bash
# cilium-benchmark.sh

set -e

SERVER_IP="10.0.0.5"
DURATION=60

echo "=== Cilium 网络基准测试 ==="
echo

echo "1. 延迟测试 (qperf)"
kubectl exec qperf-client -- qperf -t $DURATION -m $SERVER_IP latency

echo
echo "2. TCP 带宽测试"
kubectl exec qperf-client -- qperf -t $DURATION -m $SERVER_IP tcp_bw

echo
echo "3. UDP 带宽测试"
kubectl exec qperf-client -- qperf -t $DURATION -m $SERVER_IP udp_bw

echo
echo "4. Hubb le 指标"
cilium bpf metrics list

echo
echo "5. 连接追踪统计"
cilium bpf ct list | wc -l
```

### 9.4 基准测试结果解读

```
┌─────────────────────────────────────────────────────────────────────┐
│                    基准测试结果解读                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   延迟参考值:                                                         │
│   ───────────                                                        │
│   节点内 Pod-to-Pod:     5-20 µs                                     │
│   跨节点 Pod-to-Pod:     20-50 µs                                   │
│   Service 访问:          30-100 µs                                  │
│   跨集群 Pod-to-Pod:    100-300 µs                                  │
│                                                                     │
│   吞吐量参考值:                                                         │
│   ─────────────                                                        │
│   单连接 TCP:           2-5 Gbps                                     │
│   多连接 TCP (8x):     10-20 Gbps                                   │
│   DPDK 模式:            40+ Gbps                                     │
│                                                                     │
│   CPU 参考值:                                                           │
│   ─────────                                                            │
│   Cilium Agent:         1-5% 单核                                    │
│   eBPF 数据面:         <1% (几乎零开销)                              │
│   加密 (WireGuard):    5-15% 单核                                  │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 10. 监控与持续优化

### 10.1 Prometheus 指标

```yaml
# 启用 Prometheus 指标
prometheus:
  enabled: true
  port: 9090

# 关键指标
# - cilium_bpf_forward_count: 转发统计
# - cilium_bpf_drop_count: 丢包统计
# - cilium_bpf_latency: 延迟统计
# - cilium_services_total: Service 统计
```

### 10.2 Grafana Dashboard

```yaml
# 导入 Grafana Dashboard
# Dashboard ID: 18589 (Cilium)
# Dashboard ID: 17542 (Hubble)

# 关键 Panel:
# - BPF Map 使用率
# - eBPF 程序执行时间
# - Service 延迟 P50/P99
# - 连接跟踪表大小
```

### 10.3 持续监控查询

```promql
# eBPF 程序执行时间
cilium_bpf_map_ops_total{operation="lookup"} / rate(cilium_bpf_map_ops_total{operation="lookup"}[5m])

# Service 延迟
histogram_quantile(0.99, rate(cilium_service_latency_seconds_bucket[5m]))

# 丢包率
rate(cilium_drop_count_total[5m]) / rate(cilium_forward_count_total[5m])

# LRU 命中率
cilium_lb_cache_hits_total / (cilium_lb_cache_hits_total + cilium_lb_cache_misses_total)
```

---

## 11. 生产环境推荐配置

### 11.1 高性能场景

```yaml
# 高性能/低延迟配置
cluster:
  name: production

bpf:
  hostRouting: true
  clockProbe: false
  mode: native

loadBalancer:
  mode: dsr
  algorithm: maglev
  acceleration: always
  lruMapSize: 262144

bandwidth-manager:
  enabled: true
  bbr: true # 需要内核 5.18+

encryption:
  type: wireguard
```

### 11.2 高密度场景

```yaml
# 大规模集群配置
bpf:
  mapDynamicSockRecords: 262144
  natMapMaxEntries: 262144
  ctMapMaxEntries: 524288

loadBalancer:
  lruMapSize: 524288

bandwidth-manager:
  enabled: true
```

### 11.3 安全优先场景

```yaml
# 安全优先配置（略微影响性能）
bpf:
  sockmap: true
  masquerade: true

encryption:
  type: ipsec

# 启用所有审计功能
hubble:
  enabled: true
  metrics:
    enabled:
      - flow
      - dns
      - port-distribution
```

---

## 12. 性能问题排查

### 12.1 延迟高

```bash
# 1. 检查是否启用了 hostRouting
cilium config view | grep host-routing
# host-routing-enabled = true

# 2. 检查 XDP 模式
cilium bpf prog list | grep -E "xdp|tc"

# 3. 检查是否存在 NAT 转换
cilium bpf nat list | head

# 4. 检查 conntrack 延迟
cilium bpf ct list | grep -E "latency|delay"
```

### 12.2 吞吐量低

```bash
# 1. 检查网卡多队列
ethtool -l cilium+

# 2. 检查 TSO/GRO 状态
ethtool -k cilium+ | grep -E "tso|gro|gso"

# 3. 检查 MTU
ip link show cilium+ | grep mtu

# 4. 检查 BPF Map 大小
cilium bpf map list | grep -E "lb|service"

# 5. 检查 CPU 节流
cat /proc/sys/kernel/sched_rt_runtime_us
```

### 12.3 CPU 高

```bash
# 1. 检查 Agent CPU 使用
kubectl top pods -n kube-system -l k8s-app=cilium

# 2. 检查 JIT 状态
cat /proc/sys/net/core/bpf_jit_enable

# 3. 检查是否存在大量策略
cilium policy get | wc -l

# 4. 检查 Hubble 开销
cilium bpf metrics list | grep hubble
```

---

## 13. 总结

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Cilium 性能优化总结                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│   延迟优化:                                                           │
│   □ 启用 hostRouting (内核 5.10+)                                    │
│   □ 使用 DSR 模式代替 SNAT                                           │
│   □ 启用 XDP native 模式                                             │
│   □ 使用 MagLev 调度算法                                              │
│                                                                     │
│   吞吐量优化:                                                         │
│   □ 启用 TSO/GRO/GSO                                                 │
│   □ 配置网卡多队列 RSS                                               │
│   □ 使用巨帧 (MTU 9000)                                               │
│   □ 调整 BPF Map 大小                                                │
│                                                                     │
│   CPU 优化:                                                           │
│   □ 启用 JIT 编译                                                    │
│   □ 关闭不必要的功能                                                 │
│   □ 使用 CPU 亲和                                                     │
│                                                                     │
│   监控:                                                               │
│   □ 启用 Prometheus 指标                                            │
│   □ 导入 Grafana Dashboard                                           │
│   □ 定期基准测试                                                     │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 14. 系列总结

本系列从 Cilium 概述 (第一章) 到性能调优 (第四十二章)，完整覆盖了 Cilium 的：

- **基础架构**: eBPF 数据面、架构设计
- **网络功能**: ClusterIP、NodePort、LoadBalancer、VXLAN
- **安全策略**: CiliumNetworkPolicy、L7 策略、DNS 策略
- **观测能力**: Hubble Flow、Prometheus、Grafana
- **多集群**: Cluster Mesh、Global Services
- **入流量**: Ingress、Gateway API
- **服务网格**: Ambient Mode、Waypoint Proxy
- **高级特性**: 带宽管理、加密、Sockmap
- **运维**: 安装、升级、排错、性能

Cilium 作为 CNCF 毕业项目，代表了云原生网络的未来方向。eBPF 驱动的数据面在性能、安全和可观测性方面都展现出显著优势。
