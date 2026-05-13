---
title: "Cilium 深度探索 (18)：Hubble UI 可视化界面详解"
date: 2026-04-14
tags:
  - cilium
  - hubble
  - ui
  - observability
  - kubernetes
  - networking
  - service-graph
  - topology
---

> [!info] Cilium 2026 深度探索系列
> 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
> 1. [[2026-04-14-cilium-deep-dive-ch1-cilium-overview|第一章：Cilium 概述]]
> 2. [[2026-04-14-cilium-deep-dive-ch2-architecture|第二章：Cilium 架构]]
> 3. [[2026-04-14-cilium-deep-dive-ch3-ebpf-datapath|第三章：eBPF 数据面]]
> 4. [[2026-04-14-cilium-deep-dive-ch4-kube-proxy|第四章：Kube-Proxy 替代]]
> 5. [[2026-04-14-cilium-deep-dive-ch5-cni|第五章：CNI 集成]]
> 6. [[2026-04-14-cilium-deep-dive-ch6-clusterip|第六章：ClusterIP]]
> 7. [[2026-04-14-cilium-deep-dive-ch7-nodeport|第七章：NodePort]]
> 8. [[2026-04-14-cilium-deep-dive-ch8-loadbalancer|第八章：LoadBalancer]]
> 9. [[2026-04-14-cilium-deep-dive-ch9-externalip|第九章：ExternalIP]]
> 10. [[2026-04-14-cilium-deep-dive-ch10-vxlan|第十章：VXLAN]]
> 11. [[2026-04-14-cilium-deep-dive-ch11-cnp|第十一章：CiliumNetworkPolicy]]
> 12. [[2026-04-14-cilium-deep-dive-ch12-networkpolicy|第十二章：NetworkPolicy]]
> 13. [[2026-04-14-cilium-deep-dive-ch13-layer7|第十三章：L7 策略]]
> 14. [[2026-04-14-cilium-deep-dive-ch14-dns|第十四章：DNS 策略]]
> 15. [[2026-04-14-cilium-deep-dive-ch15-categories|第十五章：策略层级]]
> 16. [[2026-04-14-cilium-deep-dive-ch16-hubble-overview|第十六章：Hubble 概述]]
> 17. [[2026-04-14-cilium-deep-dive-ch17-hubble-cli|第十七章：Hubble CLI]]
> 18. **第十八章：Hubble UI** ←

---

## 1. Hubble UI 概述

Hubble UI 是 Cilium 内置的 Web 可视化界面，提供网络流量的图形化观测能力。相比 CLI，UI 更适合：

- **服务拓扑可视化**：直观展示服务间调用关系
- **实时流量监控**：动态刷新查看流量模式
- **多维度过滤**：通过界面交互快速筛选
- **团队协作**：非技术人员也能理解网络状态

```bash
# 安装并启用 Hubble UI
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.ui.enabled=true

# 访问 UI（端口转发）
kubectl port-forward -n kube-system svc/hubble-ui 8080:80

# 或者通过 NodePort 访问
kubectl patch svc -n kube-system hubble-ui -p '{"spec":{"type":"NodePort"}}'

# 访问 http://<node-ip>:<node-port>
```

### 1.1 Hubble UI 架构

```
┌─────────────────────────────────────────────────────────────┐
│                   Hubble UI 架构                            │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                    Hubble UI                          │   │
│  │              (React Web Application)                   │   │
│  │                                                        │   │
│  │   ┌────────────┐  ┌────────────┐  ┌────────────┐     │   │
│  │   │  Topology  │  │   Flow    │  │  Metrics   │     │   │
│  │   │   View     │  │   View    │  │   Cards    │     │   │
│  │   └────────────┘  └────────────┘  └────────────┘     │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ gRPC / REST                      │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │              Hubble Relay / Hubble Server            │   │
│  │                  (:4244 / :4245)                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                           │                                 │
│                           │ eBPF Flow Events                │
│                           ▼                                 │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Cilium Agent                       │   │
│  │                     (eBPF)                            │   │
│  └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 界面布局

### 2.1 主界面概览

Hubble UI 的主界面分为以下几个区域：

```
┌────────────────────────────────────────────────────────────────────────┐
│  [Logo] Cilium Hubble                              [Namespace ▼] [⚙️] │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  ┌──────────────────────────────────────────────────────────────┐    │
│  │                     Service Graph (拓扑视图)                    │    │
│  │                                                               │    │
│  │     ┌─────────┐                        ┌─────────┐            │    │
│  │     │ frontend│───────────────────────▶│api-gateway│          │    │
│  │     └─────────┘                        └─────┬───┘            │    │
│  │                                               │                │    │
│  │                          ┌────────────────────┼───────┐       │    │
│  │                          ▼                    ▼       ▼       │    │
│  │                    ┌─────────┐          ┌─────────┐ ┌─────┐   │    │
│  │                    │ backend │          │  redis  │ │ mysql│   │    │
│  │                    └─────────┘          └─────────┘ └─────┘   │    │
│  │                                                               │    │
│  └──────────────────────────────────────────────────────────────┘    │
│                                                                        │
│  ┌─────────────────────┐  ┌─────────────────────┐                     │
│  │  Flows (流量列表)    │  │  Metrics (指标卡片)  │                     │
│  │                     │  │                     │                     │
│  │  🔵 HTTP GET /api   │  │  Total: 12,345      │                     │
│  │  🔵 HTTP 200 /api  │  │  Dropped: 23 (0.2%) │                     │
│  │  🔴 TCP RST         │  │  Latency: 45ms      │                     │
│  │                     │  │                     │                     │
│  └─────────────────────┘  └─────────────────────┘                     │
│                                                                        │
├────────────────────────────────────────────────────────────────────────┤
│  Status: Connected to hubble-relay:443    Last updated: 2s ago        │
└────────────────────────────────────────────────────────────────────────┘
```

### 2.2 顶部导航栏

| 元素 | 功能 |
|:---|:---|
| **Logo + 标题** | 返回主视图 |
| **Namespace 选择器** | 过滤特定命名空间 |
| **时间范围** | 选择时间窗口（实时/5m/15m/1h/自定义） |
| **过滤器** | 快速添加过滤条件 |
| **设置图标** | 主题切换、连接配置 |

---

## 3. 服务拓扑视图 (Service Graph)

### 3.1 拓扑图概述

服务拓扑图是 Hubble UI 的核心功能，自动根据 Flow 数据构建服务间调用关系图：

```
┌─────────────────────────────────────────────────────────────┐
│              Service Graph 拓扑图                          │
│                                                             │
│    ┌─────────────────────────────────────────────────────┐  │
│    │                    production                       │  │
│    │                                                      │  │
│    │   ┌─────────┐         ┌─────────┐                    │  │
│    │   │ frontend│────────▶│api-gateway                    │  │
│    │   │  pod    │         │  (L7)    │                    │  │
│    │   └─────────┘         └────┬────┘                    │  │
│    │                            │                          │  │
│    │           ┌───────────────┼───────────────┐           │  │
│    │           ▼               ▼               ▼           │  │
│    │     ┌─────────┐    ┌─────────┐    ┌─────────┐         │  │
│    │     │ backend │    │  redis  │    │ database│         │  │
│    │     │  (L4)   │    │  (L4)   │    │  (L4)   │         │  │
│    │     └─────────┘    └─────────┘    └─────────┘         │  │
│    │                                                      │  │
│    │   Legend:                                             │  │
│    │   ● 节点 = Namespace 或 Service                       │  │
│    │   ───▶ 边 = 流量方向                                  │  │
│    │   颜色 = 流量状态（绿色=正常，红色=有丢弃）            │  │
│    │   粗细 = 流量大小                                      │  │
│    └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 节点类型

| 节点类型 | 描述 | 图标 |
|:---|:---|:---|
| **Namespace** | 命名空间聚合节点 | 🏢 |
| **Service** | Kubernetes Service | 🔷 |
| **Pod** | Pod 级别视图 | ⬡ |
| **External** | 集群外部流量 | 🌍 |

### 3.3 边的属性

每条边代表服务间的流量，包含以下属性：

| 属性 | 描述 |
|:---|:---|
| **方向** | 箭头指向流量方向 |
| **流量大小** | 边的粗细表示流量比例 |
| **协议** | TCP/UDP/HTTP/gRPC |
| **请求数** | 边上的数字标签 |
| **丢弃率** | 红色表示有丢弃 |
| **延迟** | 颜色深浅表示延迟高低 |

### 3.4 拓扑图交互

```bash
# 拓扑图支持的操作
- 拖拽节点重新布局
- 点击节点查看详情
- 双击节点展开下钻
- 滚轮缩放视图
- 右键显示上下文菜单
- 搜索定位节点
```

### 3.5 节点详情面板

点击拓扑图中的节点，弹出详情面板：

```
┌─────────────────────────────────────────────────────────────┐
│  Node Details: api-gateway                                  │
├─────────────────────────────────────────────────────────────┤
│  Type: Service                                              │
│  Namespace: production                                      │
│  ClusterIP: 10.96.0.50                                     │
│  Ports: 8080/TCP                                            │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  Outbound Traffic (出口流量)                                 │
│    to backend: 1,234 req/s (HTTP)                          │
│    to redis: 567 req/s (TCP)                                │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  Inbound Traffic (入口流量)                                  │
│    from frontend: 2,345 req/s (HTTP)                        │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  Metrics                                                    │
│    Success Rate: 99.8%                                     │
│    Avg Latency: 45ms                                       │
│    P99 Latency: 120ms                                      │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  Applied Policies                                           │
│    ✅ allow-frontend-to-api                                 │
│    ✅ api-gateway-l7-policy                                 │
│                                                             │
│  [View Flows]  [View Policies]  [Open in CLI]               │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. 流量列表视图 (Flows)

### 4.1 流量列表

流量列表提供 Flow 事件的表格视图：

```
┌────────────────────────────────────────────────────────────────────────┐
│  Flows                                     [Filter] [Export] [⚙️]    │
├────────────────────────────────────────────────────────────────────────┤
│                                                                        │
│  TIME        │ SOURCE            │ DESTINATION         │ VERDICT │ L7  │
│ ──────────────────────────────────────────────────────────────────────  │
│  10:30:01.2  │ frontend:54321    │ api-gateway:8080   │  ✅ OK  │ HTTP│
│  10:30:01.3  │ frontend:54321    │ api-gateway:8080   │  ✅ OK  │ HTTP│
│  10:30:01.4  │ frontend:54321    │ api-gateway:8080   │  🔴DROP │ TCP │
│  10:30:02.0  │ api-gateway:     │ backend:9090       │  ✅ OK  │ gRPC│
│  10:30:02.1  │ api-gateway:     │ redis:6379         │  ✅ OK  │ TCP │
│  10:30:02.5  │ backend:54322    │ database:5432      │  ✅ OK  │ TCP │
│                                                                        │
│  ◀ Prev  [1] [2] [3] [4] [5]  Next ▶                                │
└────────────────────────────────────────────────────────────────────────┘
```

### 4.2 列表列说明

| 列 | 描述 |
|:---|:---|
| **TIME** | 事件时间戳 |
| **SOURCE** | 源（Pod/Namespace:Port） |
| **DESTINATION** | 目标（Pod/Namespace:Port） |
| **VERDICT** | 判定结果（OK/DROP/AUDIT） |
| **L7** | L7 协议信息（HTTP/gRPC/DNS/SQL） |
| **POLICY** | 匹配的策略名称 |
| **DURATION** | 请求持续时间 |

### 4.3 过滤选项

流量列表支持丰富的过滤选项：

```
┌─────────────────────────────────────────────────────────────┐
│  Filter Options                                            │
│                                                             │
│  [Namespace ▼]  [Pod ▼]  [Service ▼]  [Verdict ▼]          │
│                                                             │
│  Protocol:  [HTTP ▼] [TLS ▼] [TCP ▼] [UDP ▼]              │
│                                                             │
│  Time Range:  [Last 5m ▼] [Last 15m] [Last 1h] [Custom]    │
│                                                             │
│  Search:  [________________________] 🔍                    │
│           /api/v1/products                                  │
│                                                             │
│  [x] Show dropped only                                      │
│  [x] Show L7 only                                           │
│  [ ] Show kube-system                                       │
│                                                             │
│  [Apply Filters]  [Reset]                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## 5. 指标卡片 (Metrics Cards)

### 5.1 实时指标

Hubble UI 显示关键网络指标：

```
┌────────────────────────────────────────────────────────────────────┐
│  Metrics Overview                              [Last 5m] [Refresh] │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐            │
│  │ Total Flows  │  │ Dropped      │  │ Blocked      │            │
│  │              │  │              │  │              │            │
│  │   12,345     │  │     23       │  │      0       │            │
│  │  ▲ 5%        │  │  ▲ 2%        │  │  ─ 0%        │            │
│  │  vs prev 5m  │  │  vs prev 5m  │  │  vs prev 5m  │            │
│  └──────────────┘  └──────────────┘  └──────────────┘            │
│                                                                    │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐            │
│  │ Avg Latency  │  │ P99 Latency  │  │ Throughput   │            │
│  │              │  │              │  │              │            │
│  │    45ms      │  │   120ms      │  │   2.3 Gbps   │            │
│  │  ▼ 10%       │  │  ▼ 5%        │  │  ▲ 8%        │            │
│  └──────────────┘  └──────────────┘  └──────────────┘            │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### 5.2 指标类型

| 指标 | 描述 | 来源 |
|:---|:---|:---|
| **Total Flows** | 总流量数 | Hubble Flow API |
| **Dropped** | 丢弃的流量数 | Hubble verdict=DROPPED |
| **Blocked** | 被策略阻止的流量 | Policy verdict |
| **Avg Latency** | 平均延迟 | L7 Flow 统计 |
| **P99 Latency** | P99 延迟 | L7 Flow 统计 |
| **Throughput** | 网络吞吐率 | Interface stats |

### 5.3 趋势图

点击指标卡片可以展开趋势图：

```
┌────────────────────────────────────────────────────────────────────┐
│  Dropped Flows Trend                              [Last 1h] [▼]   │
├────────────────────────────────────────────────────────────────────┤
│  50 ┤                                                           ╭─│
│     │                                                      ╭────╯ │
│  40 ┤                                                 ╭────╯       │
│     │                                            ╭────╯            │
│  30 ┤                                       ╭────╯                 │
│     │                                  ╭────╯                      │
│  20 ┤                             ╭────╯                           │
│     │                        ╭────╯                                │
│  10 ┤                   ╭────╯                                     │
│     │              ╭────╯                                          │
│   0 ┼─────────────╯────────────────────────────────────────────    │
│     10:00   10:15   10:30   10:45   11:00   11:15   11:30   11:45  │
│                                                                    │
│  ⚠️  Spike detected at 10:30 - 15 dropped flows                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 6. 流量详情面板

### 6.1 Flow 详情

点击流量列表中的某一条目，显示详细面板：

```
┌─────────────────────────────────────────────────────────────┐
│  Flow Details                                        [✕]    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  TIME                                                        │
│  2026-04-14 10:30:01.251 UTC                                │
│                                                             │
│  VERDICT                                                     │
│  ✅ Forwarded (allowed by: api-gateway-l7-policy)          │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  SOURCE                                                       │
│  Pod:        production/frontend-5f9b8c7d6-l3m4n             │
│  Workload:   Deployment/frontend                             │
│  IP:         10.0.1.45:54321                                │
│  Identity:   5421 (label: app=frontend)                      │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  DESTINATION                                                 │
│  Pod:        production/api-gateway-7d8f9c6b5-xk9pq         │
│  Workload:   Deployment/api-gateway                          │
│  Service:    api-gateway.production.svc.cluster.local:8080   │
│  IP:         10.0.2.67:8080                                 │
│  Identity:   5422 (label: app=api-gateway)                  │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  LAYER 4                                                     │
│  Protocol:  TCP                                             │
│  Flags:     SYN, ACK                                         │
│  Direction: INGRESS                                          │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  LAYER 7                                                     │
│  Protocol:  HTTP                                             │
│  Method:    GET                                              │
│  Path:      /api/v1/products/123                             │
│  Code:      200 OK                                           │
│  Latency:  45ms                                             │
│                                                             │
│  Headers:                                                   │
│  - user-agent: curl/7.68.0                                   │
│  - authorization: Bearer ***                                │
│  - x-request-id: a1b2c3d4-e5f6                              │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  POLICY MATCH                                                │
│  Ingress Rule #1: ✅ Matched                                │
│  - fromEndpoints: app=frontend                              │
│  - toPorts: 8080/TCP                                        │
│  - rules: HTTP GET /api/.*                                  │
│                                                             │
│  [Copy as JSON]  [View related flows]  [Block this flow]    │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 丢弃流量详情

当流量被丢弃时，详情面板显示丢弃原因：

```
┌─────────────────────────────────────────────────────────────┐
│  Flow Details                                        [✕]    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  TIME                                                        │
│  2026-04-14 10:30:01.400 UTC                                │
│                                                             │
│  VERDICT                                                     │
│  🔴 Dropped (reason: POLICY_DENIED)                         │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  DROP REASON                                                │
│  🔴 policy_denied                                           │
│  No matching allow rule found.                              │
│  Applied policy: default-deny                               │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  SOURCE                                                      │
│  Pod:        production/external-pod-xyz                    │
│  IP:         10.0.5.100:45678                               │
│  Identity:   Unknown (no matching endpoint)                 │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  DESTINATION                                                │
│  Pod:        production/api-gateway-7d8f9c6b5-xk9pq         │
│  Service:    api-gateway.production.svc.cluster.local:8080  │
│  IP:         10.0.2.67:8080                                 │
│                                                             │
│  ─────────────────────────────────────────────────────────  │
│  SUGGESTED ACTION                                           │
│  To allow this traffic, add a CiliumNetworkPolicy:          │
│                                                             │
│  apiVersion: cilium.io/v2                                   │
│  kind: CiliumNetworkPolicy                                  │
│  metadata:                                                   │
│    name: allow-external-to-api                              │
│  spec:                                                       │
│    endpointSelector:                                        │
│      matchLabels:                                          │
│        app: api-gateway                                     │
│    ingress:                                                 │
│    - fromCidrs:                                             │
│        - "10.0.5.0/24"                                      │
│      toPorts:                                               │
│      - port: "8080"                                         │
│        protocol: TCP                                        │
│                                                             │
│  [Apply Suggested Policy]  [View Audit Logs]               │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. 命名空间视图

### 7.1 Namespace 级别聚合

Hubble UI 支持按命名空间过滤和聚合：

```
┌────────────────────────────────────────────────────────────────────┐
│  Namespace: production                                             │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  [x] production   [ ] staging   [ ] development   [ ] kube-system │
│                                                                    │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │  Namespace Summary                                          │   │
│  │                                                              │   │
│  │  Services: 15    Pods: 45    Flows/s: 1,234               │   │
│  │  Dropped: 12      Blocked: 0   Avg Latency: 45ms           │   │
│  └────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  Top Services by Traffic                                          │
│  1. api-gateway (2,345 flows)                                     │
│  2. backend-service (1,890 flows)                                 │
│  3. frontend (1,234 flows)                                        │
│                                                                    │
│  [View Namespace Topology]  [View All Flows]  [Export]           │
└────────────────────────────────────────────────────────────────────┘
```

### 7.2 多命名空间对比

支持同时查看多个命名空间的流量对比：

```
┌────────────────────────────────────────────────────────────────────┐
│  Multi-Namespace Comparison                                        │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Namespace      │ Total Flows │ Dropped │ Blocked │ Latency       │
│ ──────────────────────────────────────────────────────────────────│
│  production     │   12,345    │   23    │    0    │   45ms        │
│  staging        │    3,456    │    5    │    0    │   52ms        │
│  development    │    1,234    │    2    │    0    │   38ms        │
│                                                                    │
│  ⚠️  production has 4.6x more dropped flows than staging         │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 8. 配置与自定义

### 8.1 主题设置

```bash
# 切换明暗主题
# Settings → Appearance → Theme
# Options: Light / Dark / System
```

### 8.2 连接设置

```bash
# 配置 Hubble Server 连接
# Settings → Connection
# - Server: localhost:4244 (默认)
# - TLS: Enabled (mTLS)
# - Timeout: 30s
```

### 8.3 刷新设置

```bash
# 实时刷新设置
# Settings → Refresh
# - Real-time: 2s interval
# - Historical: 10s interval
```

### 8.4 导出功能

```bash
# 导出流量数据
# Flows → Export → JSON / CSV / HAR

# 导出拓扑图
# Topology → Export as PNG / SVG
```

---

## 9. 集群级视图 (ClusterMesh)

在启用了 ClusterMesh 的多集群环境中，Hubble UI 支持跨集群流量可视化：

```
┌────────────────────────────────────────────────────────────────────┐
│  ClusterMesh: 2 clusters connected                                │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  ┌──────────────────────┐    ┌──────────────────────┐            │
│  │   cluster-1 (us)     │    │  cluster-2 (eu)      │            │
│  │                      │    │                      │            │
│  │  frontend ───────────┼─────────▶ backend        │            │
│  │                      │    │                      │            │
│  └──────────────────────┘    └──────────────────────┘            │
│           │                              │                        │
│           └──────────┬───────────────────┘                        │
│                      │                                            │
│               Global Service                                       │
│           (api-gateway.global)                                     │
│                                                                    │
│  Cross-cluster flows: 234/s                                        │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 10. 总结

Hubble UI 提供了强大的图形化可观测性能力：

1. **Service Graph**：自动构建服务拓扑图，直观展示服务间调用关系
2. **Flows View**：详细的流量列表，支持多维度过滤
3. **Metrics Cards**：关键指标的实时监控和趋势展示
4. **Flow Details**：完整的 Flow 详情，包括丢弃原因和策略建议
5. **Namespace Views**：命名空间级别的聚合和对比
6. **ClusterMesh Support**：多集群统一观测视图

Hubble UI 的优势：
- **零配置**：开箱即用，自动发现服务拓扑
- **实时性**：秒级延迟的流量更新
- **易用性**：非技术人员也能理解网络状态
- **集成化**：与 Cilium 策略深度集成，可直接查看策略匹配结果

下一章我们将学习 **Prometheus Metrics**，了解如何将 Hubble 指标与 Prometheus/Grafana 集成进行长期存储和告警。
