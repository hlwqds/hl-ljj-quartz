---
title: "Cilium 深度探索 (19)：Prometheus 指标与 Grafana 可视化"
date: 2026-04-14
tags:
  - cilium
  - prometheus
  - grafana
  - metrics
  - observability
  - kubernetes
  - monitoring
  - alerting
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
> 18. [[2026-04-14-cilium-deep-dive-ch18-hubble-ui|第十八章：Hubble UI]]
> 19. **第十九章：Prometheus 指标** ←

---

## 1. Prometheus 指标概述

Cilium 和 Hubble 内置完整的 Prometheus 指标支持，无需额外安装探针即可获取网络相关的时序数据。这些指标涵盖：

- **网络流量指标**：吞吐量、连接数、丢包率
- **策略指标**：策略匹配次数、拒绝次数
- **eBPF 性能指标**：转发延迟、内存使用
- **Hubble 指标**：Flow 处理速度、API 调用延迟
- **L7 代理指标**：HTTP/gRPC 请求率、延迟分布

```bash
# 安装 Cilium 时启用 Prometheus 指标
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true \
  --set hubble.metrics.enabled=true \
  --set hubble.metrics.port=9091

# 验证指标端点
kubectl get svc -n kube-system | grep prometheus
# cilium-metrics     ClusterIP   10.96.0.100   <none>   9090/TCP
# hubble-metrics     ClusterIP   10.96.0.101   <none>   9091/TCP

# 直接访问指标
curl -s http://localhost:9090/metrics | head -50
```

### 1.1 指标暴露架构

```
┌────────────────────────────────────────────────────────────────────┐
│                    Prometheus 指标暴露架构                          │
│                                                                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                      Cilium Agent                            │   │
│  │                                                              │   │
│  │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │   │
│  │   │   eBPF      │  │   Hubble   │  │    L7       │       │   │
│  │   │   Maps      │  │   Server    │  │   Proxy     │       │   │
│  │   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘       │   │
│  │          │                │                │               │   │
│  │          └────────────────┼────────────────┘               │   │
│  │                           │                                │   │
│  │                    ┌──────▼──────┐                        │   │
│  │                    │ Prometheus  │                        │   │
│  │                    │  Exporter   │                        │   │
│  │                    │   (:9090)   │                        │   │
│  │                    └──────┬──────┘                        │   │
│  └───────────────────────────┼─────────────────────────────────┘   │
│                              │                                      │
│                              ▼                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                        Prometheus                             │  │
│  │                     (scrape & store)                          │  │
│  └───────────────────────────┬───────────────────────────────────┘  │
│                              │                                      │
│                              ▼                                      │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                       Grafana                                  │  │
│  │                    (visualize dashboards)                       │  │
│  └───────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. Cilium 核心指标

### 2.1 网络流量指标

| 指标名称 | 类型 | 描述 |
|:---|:---|:---|
| `cilium_forwarded_total` | Counter | 转发的流量总数 |
| `cilium_dropped_total` | Counter | 丢弃的流量总数 |
| `cilium_audited_total` | Counter | 审计的流量总数 |
| `cilium_processed_total` | Counter | 处理的流量总数 |

```promql
# 流量转发率
sum(rate(cilium_forwarded_total[5m])) / 
sum(rate(cilium_forwarded_total[5m]) + rate(cilium_dropped_total[5m]))

# 丢弃率
sum(rate(cilium_dropped_total[5m])) * 100 / 
sum(rate(cilium_forwarded_total[5m]) + rate(cilium_dropped_total[5m]))
```

### 2.2 端点指标

| 指标名称 | 类型 | 描述 |
|:---|:---|:---|
| `cilium_endpoint_state` | Gauge | 端点状态分布（标签：endpoint_state） |
| `cilium_endpoint_count` | Gauge | 端点总数 |
| `cilium_endpoint_regenerations` | Counter | 端点策略重建次数 |

```promql
# 按状态统计端点
sum(cilium_endpoint_state) by (state)

# 端点数量趋势
sum(cilium_endpoint_count)

# 重建失败率
sum(rate(cilium_endpoint_regenerations{outcome="fail"}[5m])) / 
sum(rate(cilium_endpoint_regenerations[5m]))
```

### 2.3 策略指标

| 指标名称 | 类型 | 描述 |
|:---|:---|:---|
| `cilium_policy_l7_total` | Counter | L7 策略匹配次数 |
| `cilium_policy_verdict` | Counter | 策略判定（标签：verdict, direction） |
| `cilium_policy_count` | Gauge | 策略总数 |

```promql
# L7 策略拒绝率
sum(rate(cilium_policy_verdict{verdict="denied", direction="ingress"}[5m])) / 
sum(rate(cilium_policy_verdict{direction="ingress"}[5m]))

# HTTP 200 成功率
sum(rate(cilium_policy_l7_total{http_status="200"}[5m])) / 
sum(rate(cilium_policy_l7_total{http_status=~"2.*"}[5m]))
```

### 2.4 eBPF 指标

| 指标名称 | 类型 | 描述 |
|:---|:---|:---|
| `cilium_bpf_map_ops_total` | Counter | BPF Map 操作次数 |
| `cilium_bpf_syscall_duration_seconds` | Histogram | BPF 系统调用延迟 |
| `cilium_datapath_conntrack_gc_duration_seconds` | Histogram | Conntrack GC 耗时 |

```promql
# BPF Map 操作错误率
sum(rate(cilium_bpf_map_ops_total{outcome="error"}[5m])) / 
sum(rate(cilium_bpf_map_ops_total[5m]))

# Conntrack GC 延迟 P99
histogram_quantile(0.99, 
  sum(rate(cilium_datapath_conntrack_gc_duration_seconds_bucket[5m])) by (le)
)
```

### 2.5 服务/负载均衡指标

| 指标名称 | 类型 | 描述 |
|:---|:---|:---|
| `cilium_service_endpoints` | Gauge | Service 的后端数量 |
| `cilium_nodeport_local` | Counter | NodePort 本地连接数 |
| `cilium_loadbalancer_routes` | Gauge | 负载均衡路由数 |

```promql
# Service 后端健康率
sum(cilium_service_endpoints{health="healthy"}) by (service_id) / 
sum(cilium_service_endpoints) by (service_id)

# NodePort 连接分布
sum(rate(cilium_nodeport_local[5m])) by (protocol)
```

---

## 3. Hubble 指标

### 3.1 Hubble Metrics 配置

Hubble 暴露一组预定义的 L7 指标：

```bash
# 启用 Hubble Metrics
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.metrics.enabled=true \
  --set hubble.metrics.enableOpenTelemetry=true

# 配置要启用的指标
# Hubbl 指标列表
# - flows, flow:min, flow:summary - Flow 相关
# - nodeport, nodeport:minimal - NodePort 流量
# -旗袍,旗袍:minimal - L7 代理
# - dns, dns:query:min - DNS 查询
# - http, http:min, http:metrics - HTTP 指标
# - icmp, icmp:minimal - ICMP
```

### 3.2 Hubble 指标列表

| 指标名称 | 类型 | 描述 |
|:---|:---|:---|
| `hubble_flows_total` | Counter | Flow 事件总数 |
| `hubble_flows_processed_total` | Counter | 已处理 Flow 数 |
| `hubble_http_request_total` | Counter | HTTP 请求总数 |
| `hubble_http_requests_duration_seconds` | Histogram | HTTP 请求延迟 |
| `hubble_dns_queries_total` | Counter | DNS 查询总数 |
| `hubble_dns_response_total` | Counter | DNS 响应总数 |

```yaml
# 自定义 Hubble Metrics 配置
apiVersion: cilium.io/v2alpha1
kind: CiliumClusterwideHubbleMetrics
metadata:
  name: custom-metrics
spec:
  -旗袍
  - http
  - dns
  - nodeport
```

### 3.3 HTTP 指标详解

```promql
# HTTP 请求率（按路径聚合）
sum(rate(hubble_http_request_total[5m])) by (method, path)

# HTTP 延迟分布
histogram_quantile(0.99, 
  sum(rate(hubble_http_requests_duration_seconds_bucket[5m])) by (le, method)
)

# HTTP 错误率（4xx + 5xx）
sum(rate(hubble_http_request_total{status_code=~"4.."}[5m])) + 
sum(rate(hubble_http_request_total{status_code=~"5.."}[5m]))

# Top 10 最慢端点
topk(10, 
  sum(rate(hubble_http_requests_duration_seconds_sum[5m])) by (path) / 
  sum(rate(hubble_http_requests_duration_seconds_count[5m])) by (path)
)
```

### 3.4 DNS 指标详解

```promql
# DNS 查询率（按类型）
sum(rate(hubble_dns_queries_total[5m])) by (qtype)

# DNS 响应率
sum(rate(hubble_dns_response_total[5m]))

# NXDOMAIN 错误率
sum(rate(hubble_dns_response_total{rcode="NXDOMAIN"}[5m])) / 
sum(rate(hubble_dns_queries_total[5m]))

# 外部 DNS 查询分布
sum(rate(hubble_dns_queries_total{registry="external"}[5m])) by (domain)
```

---

## 4. Prometheus Operator 集成

### 4.1 ServiceMonitor 配置

使用 Prometheus Operator 时，通过 ServiceMonitor 自动发现指标：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cilium
  namespace: kube-system
  labels:
    release: prometheus  # 需要与 Prometheus 配置的 matchLabel 一致
spec:
  jobLabel: cilium
  selector:
    matchLabels:
      k8s-app: cilium
  endpoints:
    - port: metrics
      interval: 10s
      path: /metrics
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: hubble
  namespace: kube-system
  labels:
    release: prometheus
spec:
  jobLabel: hubble
  selector:
    matchLabels:
      k8s-app: hubble
  endpoints:
    - port: hubble-metrics
      interval: 10s
      path: /metrics
```

### 4.2 PrometheusRule 配置

创建告警规则：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-alerts
  namespace: kube-system
  labels:
    app: cilium
    severity: warning
spec:
  groups:
    - name: cilium-network
      rules:
        - alert: CiliumHighDropRate
          expr: |
            sum(rate(cilium_dropped_total[5m])) * 100 / 
            (sum(rate(cilium_forwarded_total[5m])) + sum(rate(cilium_dropped_total[5m]))) > 1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Cilium drop rate exceeds 1%"
            description: "Cluster {{ $labels.cluster }} drop rate is {{ $value }}%"

        - alert: CiliumEndpointRegenerationFailure
          expr: |
            sum(rate(cilium_endpoint_regenerations{outcome="fail"}[5m])) > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Cilium endpoint regeneration failures detected"

        - alert: CiliumL7ProxyHighLatency
          expr: |
            histogram_quantile(0.99, 
              sum(rate(cilium_proxy_redirect_duration_seconds_bucket[5m])) by (le)
            ) > 0.5
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Cilium L7 proxy P99 latency exceeds 500ms"

        - alert: HubbleHighFlowDropRate
          expr: |
            sum(rate(hubble_flows_total{verdict="DROPPED"}[5m])) /
            sum(rate(hubble_flows_total[5m])) > 0.05
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Hubble flow drop rate exceeds 5%"
```

### 4.3 PodMonitor（可选）

针对每个 Pod 的指标监控：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cilium-agent
  namespace: kube-system
spec:
  selector:
    matchLabels:
      k8s-app: cilium
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      interval: 15s
  namespaceSelector:
    matchNames:
      - kube-system
```

---

## 5. Grafana Dashboard

### 5.1 Cilium Dashboard 概览

Cilium 官方提供 Grafana Dashboard，包含以下面板：

```
┌────────────────────────────────────────────────────────────────────┐
│  Cilium Network Overview Dashboard                                  │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Row 1: Network Overview                                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │ Forwarded/s  │  │ Dropped/s    │  │ Policies     │              │
│  │              │  │              │  │              │              │
│  │  12,345      │  │  23 (0.2%)   │  │  45 active   │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│                                                                    │
│  Row 2: Traffic Trends                                             │
│  ┌─────────────────────────────────────────────────────────────┐  │
│  │  Forwarded vs Dropped (rate/5m)                             │  │
│  │                                                             │  │
│  │  15k ┤ ════════════════════════════                        │  │
│  │      │                        ═══════                       │  │
│  │  10k ┤ ═══════════════════════════                         │  │
│  │      │                                                    │  │
│  │   5k ┤ ═══════════════                                    │  │
│  │      │        ↑ Dropped (P99 threshold line)               │  │
│  │      └────────────────────────────────────────────────────│  │
│  └─────────────────────────────────────────────────────────────┘  │
│                                                                    │
│  Row 3: Endpoint & Service Stats                                   │
│  ┌────────────────────────┐  ┌────────────────────────────────┐  │
│  │ Endpoint States        │  │ Service Backend Health         │  │
│  │                        │  │                                 │  │
│  │ ready: 45    regenerating│  │ healthy: 90%                  │  │
│  │ not-ready: 2  : 0       │  │ unhealthy: 10%                 │  │
│  └────────────────────────┘  └────────────────────────────────┘  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### 5.2 Hubble Dashboard 概览

```
┌────────────────────────────────────────────────────────────────────┐
│  Hubble Observability Dashboard                                    │
├────────────────────────────────────────────────────────────────────┤
│                                                                    │
│  Row 1: Flow Summary                                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │ Total Flows  │  │ Forwarded    │  │ Dropped      │              │
│  │   1,234,567  │  │   1,230,000  │  │     4,567    │              │
│  │              │  │   (99.6%)    │  │   (0.4%)     │              │
│  └──────────────┘  └──────────────┘  └──────────────┘              │
│                                                                    │
│  Row 2: HTTP Metrics                                              │
│  ┌────────────────────────────┐  ┌────────────────────────────┐  │
│  │ HTTP Request Rate          │  │ HTTP Latency P50/P99       │  │
│  │                            │  │                             │  │
│  │  5k/s ┤ ═══════           │  │  P99: 120ms ────────       │  │
│  │       │                    │  │  P50: 45ms  ─────         │  │
│  │       └────────────────────│  │                             │  │
│  └────────────────────────────┘  └────────────────────────────┘  │
│                                                                    │
│  Row 3: DNS & ICMP                                                 │
│  ┌────────────────────────────┐  ┌────────────────────────────┐  │
│  │ DNS Query Rate            │  │ ICMP                       │  │
│  │                            │  │                             │  │
│  │  A: 1k/s   AAAA: 800/s    │  │  Rate: 100/s               │  │
│  │  MX: 50/s   CNAME: 200/s  │  │  Latency: 2ms             │  │
│  └────────────────────────────┘  └────────────────────────────┘  │
│                                                                    │
└────────────────────────────────────────────────────────────────────┘
```

### 5.3 导入 Dashboard

```bash
# 方法 1: Grafana UI
# 1. 访问 Grafana → Dashboards → Import
# 2. 输入 Dashboard ID: 17576 (Cilium) 或 17729 (Hubble)
# 3. 选择 Prometheus 数据源
# 4. 点击 Import

# 方法 2: kubectl
kubectl create configmap grafana-dashboards-cilium \
  --from-file=cilium-dashboard.json \
  --namespace monitoring

# 方法 3: Grafana Operator
kubectl apply -f CiliumDashboard.yaml
```

### 5.4 常用 Panel 模板

```promql
# 流量转发率（百分比）
100 - (
  sum(rate(cilium_dropped_total[5m])) * 100 / 
  (sum(rate(cilium_forwarded_total[5m])) + sum(rate(cilium_dropped_total[5m])))
)

# 端点状态分布
sum(cilium_endpoint_state) by (state)

# Service 后端健康率
sum(cilium_service_endpoints{health="healthy"}) by (service_name) / 
sum(cilium_service_endpoints) by (service_name) * 100

# HTTP 请求率 Top 10
topk(10, sum(rate(hubble_http_request_total[5m])) by (path))

# L7 代理延迟 P99
histogram_quantile(0.99, 
  sum(rate(cilium_proxy_redirect_duration_seconds_bucket[5m])) by (le, service)
)

# NodePort 连接趋势
sum(rate(cilium_nodeport_local[5m])) by (protocol, node)

# DNS 查询分布
sum(rate(hubble_dns_queries_total[5m])) by (qtype)
```

---

## 6. 告警配置

### 6.1 关键告警规则

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cilium-critical-alerts
  namespace: kube-system
spec:
  groups:
    - name: cilium.critical
      rules:
        # 流量丢弃率过高
        - alert: CiliumHighDropRate
          expr: |
            sum(rate(cilium_dropped_total[5m])) * 100 /
            (sum(rate(cilium_forwarded_total[5m])) + sum(rate(cilium_dropped_total[5m]))) > 5
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Cilium drop rate exceeds 5%"
            runbook_url: "https://docs.cilium.io/en/stable/configuration/

#troubleshooting#high-drop-rate"

        # 端点重建失败
        - alert: CiliumEndpointRegenerationFailure
          expr: rate(cilium_endpoint_regenerations{outcome="fail"}[5m]) > 0.1
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Cilium endpoint regeneration failures"

        # L7 代理延迟过高
        - alert: CiliumL7ProxyLatencyHigh
          expr: |
            histogram_quantile(0.99, 
              sum(rate(cilium_proxy_redirect_duration_seconds_bucket[5m])) by (le)
            ) > 1
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "Cilium L7 proxy P99 latency exceeds 1s"

        # Hubble Flow 处理积压
        - alert: HubbleFlowProcessingBacklog
          expr: hubble_flows_processed_total - hubble_flows_total < 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Hubble flow processing backlog detected"

        # DNS 错误率过高
        - alert: HubbleDNSErrorRateHigh
          expr: |
            sum(rate(hubble_dns_response_total{rcode=~"FORMERR|SERVFAIL|NXDOMAIN"}[5m])) /
            sum(rate(hubble_dns_queries_total[5m])) > 0.1
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "DNS error rate exceeds 10%"
```

### 6.2 告警路由配置

```yaml
# AlertManager 配置示例
receivers:
  - name: 'cilium-alerts-slack'
    slack_configs:
      - channel: '#alerts-cilium'
        title: 'Cilium Alert: {{ .GroupLabels.alertname }}'
        text: |
          {{ range .Alerts }}
          *Alert:* {{ .Annotations.summary }}
          *Description:* {{ .Annotations.description }}
          *Severity:* {{ .Labels.severity }}
          *Cluster:* {{ .Labels.cluster }}
          *Value:* {{ .Value }}
          {{ end }}
  - name: 'cilium-alerts-pagerduty'
    pagerduty_configs:
      - service_key: <PAGERDUTY_KEY>
        severity: critical

route:
  group_by: ['alertname', 'cluster']
  match:
    severity: critical
  receiver: cilium-alerts-pagerduty
  routes:
    - match:
        severity: warning
      receiver: cilium-alerts-slack
```

---

## 7. 自定义指标采集

### 7.1 添加自定义指标

Cilium 支持通过 eBPF 添加自定义指标：

```c
// 自定义 eBPF 指标示例
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>

// 定义指标 Map
struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, 256);
    __type(key, __u32);
    __type(value, __u64);
} custom_metrics SEC(".maps");

// 在数据包处理中添加指标
SEC("tc_ingress")
int handle_ingress(struct __ctx_buff *ctx) {
    __u32 key = 0;
    __u64 *cnt = bpf_map_lookup_elem(&custom_metrics, &key);
    if (cnt)
        (*cnt)++;
    
    return TC_ACT_OK;
}
```

### 7.2 Hubble OpenTelemetry Metrics

```yaml
# 启用 OpenTelemetry 指标导出
apiVersion: cilium.io/v2alpha1
kind: CiliumHubbleMetrics
metadata:
  name: otel-metrics
spec:
  -旗袍
  - http
  - dns
  openTelemetry:
    enabled: true
    endpoint: otel-collector:4317
    insecure: true
```

---

## 8. 长期存储与容量规划

### 8.1 Prometheus 存储配置

```yaml
# Prometheus 存储配置（持久化）
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: cilium-monitoring
spec:
  retention: 30d
  retentionSize: 100GB
  storage:
    volumeClaimTemplate:
      spec:
        resources:
          requests:
            storage: 100Gi
        storageClassName: fast-ssd
  ruleSelector:
    matchLabels:
      app: cilium
  serviceMonitorSelector:
    matchLabels:
      release: prometheus
```

### 8.2 容量规划参考

| 集群规模 | 端点数 | 指标点/秒 | 存储建议 |
|:---|:---|:---|:---|
| 小型（<50 节点） | 500 | ~5,000 | 50GB / 30d |
| 中型（50-200 节点） | 5,000 | ~50,000 | 200GB / 30d |
| 大型（200+ 节点） | 20,000 | ~200,000 | 500GB / 30d |

---

## 9. 总结

Cilium 和 Hubble 的 Prometheus 指标提供了全面的网络可观测性：

1. **Cilium 核心指标**：转发/丢弃流量、端点状态、策略匹配
2. **Hubble L7 指标**：HTTP/gRPC/DNS 请求率、延迟分布
3. **eBPF 性能指标**：Map 操作延迟、Conntrack GC
4. **Service 指标**：负载均衡路由、后端健康状态

与 Prometheus/Grafana 集成后可以实现：
- **实时监控 Dashboard**：关键指标一目了然
- **历史趋势分析**：长期数据存储和分析
- **智能告警**：基于指标阈值的自动化告警
- **容量规划**：基于历史数据的资源规划

下一章我们将学习 **OpenTelemetry 集成**，了解如何将 Hubble 与分布式追踪系统结合，实现端到端的应用性能追踪。
