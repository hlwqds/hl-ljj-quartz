---
title: "Cilium 深度探索 (20)：OpenTelemetry 分布式追踪集成"
date: 2026-04-14
tags:
  - cilium
  - hubble
  - opentelemetry
  - tracing
  - observability
  - distributed-tracing
  - kubernetes
  - ebpf
---

> [!info] Cilium 2026 深度探索系列 0. [[2026-04-14-cilium-deep-dive-series-index|系列索引]]
>
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
> 19. [[2026-04-14-cilium-deep-dive-ch19-prometheus|第十九章：Prometheus 指标]]
> 20. **第二十章：OpenTelemetry 集成** ←

---

## 1. OpenTelemetry 概述

OpenTelemetry（OTel）是 CNCF 的可观测性标准项目，提供了**分布式追踪（Traces）**、**指标（Metrics）**和**日志（Logs）**的统一采集标准。Hubble 从 v1.12 开始支持 OpenTelemetry 集成，可以将 Flow 数据导出为分布式追踪上下文，实现：

- **网络路径追踪**：端到端的网络流量可视化
- **跨服务调用追踪**：与现有 APM 系统集成
- **延迟根因分析**：从网络层面到应用层面的全链路分析
- **多集群追踪**：ClusterMesh 环境下的跨集群追踪

```
┌────────────────────────────────────────────────────────────────────┐
│                OpenTelemetry 架构概览                               │
│                                                                     │
│  ┌────────────┐    ┌────────────┐    ┌────────────┐              │
│  │ Application│    │ Cilium/eBPF│    │  Envoy     │              │
│  │   (OTel)   │    │   (Hubble)  │    │  (L7 Proxy) │              │
│  └─────┬──────┘    └──────┬──────┘    └──────┬──────┘              │
│        │                   │                   │                    │
│        │    Traces         │   Network Flows   │                    │
│        └───────────────────┼───────────────────┘                    │
│                            │                                        │
│                            ▼                                        │
│                  ┌─────────────────┐                               │
│                  │  OTel Collector │                               │
│                  │    (:4317/4318)   │                               │
│                  └────────┬────────┘                               │
│                           │                                         │
│         ┌─────────────────┼─────────────────┐                       │
│         ▼                 ▼                 ▼                       │
│  ┌────────────┐   ┌────────────┐   ┌────────────┐              │
│  │  Jaeger    │   │  Tempo     │   │  Zipkin    │              │
│  │  (Trace)   │   │  (Trace)   │   │  (Trace)   │              │
│  └────────────┘   └────────────┘   └────────────┘              │
└────────────────────────────────────────────────────────────────────┘
```

### 1.1 核心概念

| 概念            | 描述                                   |
| :-------------- | :------------------------------------- |
| **Trace**       | 完整的请求路径，从开始到结束           |
| **Span**        | Trace 中的一个工作单元                 |
| **SpanContext** | 跨进程传播的上下文（TraceID + SpanID） |
| **Baggage**     | 随请求传播的键值对                     |
| **Exporter**    | 导出器，将数据发送到后端               |

### 1.2 Hubble 与 OTel 的关系

Hubble 不替代应用层的 OTel SDK，而是**补充网络层面的可见性**：

```
┌────────────────────────────────────────────────────────────────────┐
│                 全链路可观测性分层                                    │
│                                                                     │
│  Application Layer (OTel SDK)                                       │
│  ├── 业务 Span（订单创建、支付处理）                                │
│  ├── 自定义指标（订单金额、用户行为）                               │
│  └── 日志（业务日志）                                               │
│                           │                                          │
│                           ▼                                          │
│  L7 Proxy Layer (Envoy/Waypoint)                                    │
│  ├── HTTP/gRPC Span（HTTP 方法、路径、状态码）                     │
│  └── L7 指标（请求率、延迟分布）                                    │
│                           │                                          │
│                           ▼                                          │
│  Network Layer (Cilium/Hubble/OTel)                                 │
│  ├── Flow Trace（网络流上下文）                                     │
│  ├── 连接追踪（TCP 连接建立/关闭）                                  │
│  └── 策略判定（allow/deny 追踪）                                    │
└────────────────────────────────────────────────────────────────────┘
```

---

## 2. Hubble OpenTelemetry 集成架构

### 2.1 集成模式

Hubble 支持两种 OpenTelemetry 集成模式：

```
┌────────────────────────────────────────────────────────────────────┐
│                  Hubble OTel 集成模式                              │
│                                                                     │
│  Mode 1: OTel Metrics (Prometheus → OTel)                          │
│  ────────────────────────────────────────                          │
│  Hubble Metrics → OpenTelemetry Collector → Prometheus/OTel Backend│
│  (histogram)     (metric transform)       (Tempo/Jaeger)           │
│                                                                     │
│  Mode 2: OTel Traces (Hubble Flow → OTel Trace)                   │
│  ────────────────────────────────────────                          │
│  Hubble Flow Events → OpenTelemetry Collector → Trace Backend      │
│  (network trace)   (span generation)       (Tempo/Jaeger)          │
│                                                                     │
└────────────────────────────────────────────────────────────────────┘
```

### 2.2 架构组件

```
┌────────────────────────────────────────────────────────────────────┐
│                   Hubble OTel 数据流                                │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                        Cilium Agent                             │ │
│  │                                                               │ │
│  │   eBPF Flow Hook ──→ Flow Events ──→ Hubble Server          │ │
│  │                                    │                           │ │
│  │                                    │ gRPC                       │ │
│  │                                    ▼                           │ │
│  │                         ┌────────────────┐                   │ │
│  │                         │ Hubble Relay  │                   │ │
│  │                         │                │                   │ │
│  │                         │ OTel Exporter  │                   │ │
│  │                         └───────┬────────┘                   │ │
│  └─────────────────────────────────┼─────────────────────────────┘ │
│                                    │                                 │
│                                    │ OTLP (gRPC/HTTP)               │
│                                    ▼                                 │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │                   OpenTelemetry Collector                       │ │
│  │                                                               │ │
│  │   Receivers:        Processors:        Exporters:            │ │
│  │   - otlp            - batch            - jaeger               │ │
│  │   - prometheus      - memory_limiter   - tempo                │ │
│  │   - hubble (via     - k8sattributes    - prometheus          │ │
│  │     otlp)                                - otlp               │ │
│  └───────────────────────────────────────────────────────────────┘ │
│                                    │                                 │
│                         ┌──────────┼──────────┐                    │
│                         ▼          ▼          ▼                     │
│                   ┌─────────┐ ┌────────┐ ┌─────────┐              │
│                   │  Jaeger  │ │  Tempo  │ │ Zipkin  │              │
│                   │ (trace)  │ │ (trace) │ │(trace)  │              │
│                   └─────────┘ └────────┘ └─────────┘              │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. 配置与部署

### 3.1 前提条件

- Cilium >= 1.12
- Hubble Relay 启用
- OpenTelemetry Collector 部署
- 目标追踪后端（Jaeger/Tempo/Zipkin）

### 3.2 安装 OpenTelemetry Collector

```bash
# 使用 Operator 安装
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml

# 创建 OTel Collector 实例
cat << 'EOF' | kubectl apply -f -
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: cilium-otel
  namespace: kube-system
spec:
  mode: deployment
  config: |
    receivers:
      otlp:
        protocol:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

    processors:
      batch:
        timeout: 1s
        send_batch_size: 1024
      memory_limiter:
        limit_mib: 512
        spike_limit_mib: 128

    exporters:
      jaeger:
        endpoint: jaeger-collector.observability:14250
        tls:
          insecure: true
      prometheus:
        endpoint: "0.0.0.0:8889"

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [jaeger]
        metrics:
          receivers: [otlp]
          processors: [memory_limiter, batch]
          exporters: [prometheus]
EOF
```

### 3.3 启用 Hubble OTel Metrics

```bash
# 通过 Helm 启用
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.metrics.enabled=true \
  --set hubble.metrics.enableOpenTelemetry=true \
  --set hubble.metrics={flows,http,dns,旗袍,nodeport}

# 或者通过 CiliumClusterwideHubbleMetrics
cat << 'EOF' | kubectl apply -f -
apiVersion: cilium.io/v2alpha1
kind: CiliumClusterwideHubbleMetrics
metadata:
  name: otel-metrics
spec:
  -旗袍
  - http
  - dns
  - nodeport
  openTelemetry:
    enabled: true
    endpoint: "cilium-otel-collector.kube-system:4317"
    insecure: true
    serviceName: "cilium-hubble"
EOF
```

### 3.4 验证 OTel 集成

```bash
# 检查 Hubble OTel 配置
kubectl get ciliumclusterwidehubblemetrics

# 检查 OTel Collector 日志
kubectl logs -n kube-system deployment/cilium-otel-collector

# 测试 OTLP 连接
grpcurl -plaintext -d '{"resourceSpans":[{"spans":[{"name":"test","traceId":"0123456789abcdef0123456789abcdef","spanId":"0123456789abcdef"}]}]}' localhost:4317 opentelemetry.proto.collector.trace.v1.TraceService/Export

# 在 Jaeger UI 中查看 traces
# http://jaeger:16686/search?service=cilium-hubble
```

---

## 4. 追踪数据模型

### 4.1 Hubble Flow 作为 Span

Hubble 将每个 Flow 事件转换为 OpenTelemetry Span：

```json
{
  "traceId": "abc123def456...",
  "spanId": "span789...",
  "name": "tcp/flow",
  "kind": "SPAN_KIND_INTERNAL",
  "status": {
    "code": "STATUS_CODE_OK"
  },
  "attributes": {
    "source.namespace": "production",
    "source.pod_name": "frontend-5f9b8c7d6-l3m4n",
    "source.ip": "10.0.1.45",
    "source.port": 54321,
    "destination.namespace": "production",
    "destination.pod_name": "api-gateway-7d8f9c6b5-xk9pq",
    "destination.ip": "10.0.2.67",
    "destination.port": 8080,
    "verdict": "FORWARDED",
    "protocol": "TCP",
    "traffic_direction": "INGRESS",
    "cilium.identity": 5421,
    "cilium.endpoint_id": 1234
  },
  "startTimeUnixNano": "1700000000000000000",
  "endTimeUnixNano": "1700000000045000000",
  "durationNano": 45000000
}
```

### 4.2 Span 层级结构

Hubble Flow Span 采用层级结构：

```
Root Span (HTTP Request)
├── Span: L4 Connection Setup
│   ├── Span: TCP SYN
│   ├── Span: TCP SYN-ACK
│   └── Span: TCP ACK
├── Span: HTTP Request (L7)
│   ├── Span: HTTP Headers
│   └── Span: HTTP Body (optional)
└── Span: L4 Connection Teardown
    ├── Span: TCP FIN
    └── Span: TCP FIN-ACK
```

### 4.3 TraceContext 传播

Hubble 支持 W3C TraceContext 和 B3 传播格式：

```bash
# HTTP Header 中的 TraceContext
# W3C TraceContext
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
tracestate: ""

# B3 (Zipkin 兼容)
X-B3-TraceId: 0af7651916cd43dd8448eb211c80319c
X-B3-SpanId: b7ad6b7169203331
X-B3-Sampled: 1
```

---

## 5. 与应用层 OTel 集成

### 5.1 端到端追踪上下文

当应用层使用 OTel SDK 时，Hubble 可以将网络流量与业务 Span 关联：

```go
// 应用代码示例（Go）
package main

import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/trace"
)

func handleRequest(ctx context.Context) {
    // 创建业务 Span
    tracer := otel.Tracer("my-app")
    span := tracer.Start(ctx, "process-order")
    defer span.End()

    span.SetAttributes(
        attribute.String("order.id", "12345"),
        attribute.Float64("order.amount", 99.99),
    )

    // 业务逻辑会自动传播 TraceContext
    callBackend(span.Context())
}

// HTTP 客户端会自动注入 TraceContext headers
func callBackend(ctx trace.SpanContext) {
    req, _ := http.NewRequest("GET", "http://backend:8080/api", nil)

    // OTel 自动注入 TraceContext 到 HTTP headers
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))

    http.DefaultClient.Do(req)
}
```

### 5.2 网络 Span 与应用 Span 关联

Hubble Flow Span 通过共享 TraceID 与应用层 Span 关联：

```
┌────────────────────────────────────────────────────────────────────┐
│                    关联的 Trace 视图                                │
│                                                                     │
│  trace_id: abc123def456                                           │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  [App Span] order-service.handleRequest                      │  │
│  │  trace_id=abc123def456                                      │  │
│  │  span_id=111111                                              │  │
│  │                                                              │  │
│  │   ├─[App Span] order-service.callBackend                    │  │
│  │   │  trace_id=abc123def456                                  │  │
│  │   │  span_id=222222                                         │  │
│  │   │                                                          │  │
│  │   │   ├─[Hubble Flow] TCP 10.0.1.45→10.0.2.67:8080         │  │
│  │   │   │  trace_id=abc123def456                              │  │
│  │   │   │  span_id=333333 (link)                              │  │
│  │   │   │  verdict=FORWARDED                                  │  │
│  │   │   │                                                      │  │
│  │   │   └─[Hubble Flow] HTTP GET /api/orders                  │  │
│  │   │      trace_id=abc123def456                              │  │
│  │   │      span_id=444444 (link)                              │  │
│  │   │      http.method=GET                                    │  │
│  │   │      http.route=/api/orders                            │  │
│  │   │      http.status_code=200                               │  │
│  │   │                                                              │  │
│  │   └─[App Span] order-service.processResponse                 │  │
│  │      trace_id=abc123def456                                  │  │
│  │      span_id=555555                                         │  │
│  └──────────────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```

---

## 6. 可视化与分析

### 6.1 Jaeger 集成

```yaml
# Jaeger Collector 配置
apiVersion: jaegertracing.io/v1
kind: Jaeger
metadata:
  name: cilium-tracing
  namespace: observability
spec:
  agent:
    image: jaegertracing/all-in-one:latest
  collector:
    otlp:
      enabled: true
      grpc-server-host: 0.0.0.0
      grpc-server-port: 4317
  query:
    options:
      - --query.base-path=/search
  ui:
    options:
      - trace-detailSpanLatencies
      - trace-detailLogs
```

### 6.2 Grafana Tempo 集成

```yaml
# Grafana Tempo 配置
apiVersion: tempo.io/v1alpha1
kind: TempoStack
metadata:
  name: cilium-tempo
  namespace: observability
spec:
  storage:
    secret:
      type: s3
      secret: tempo-s3-credentials
  config:
    overrides:
      defaults:
        max_bytes_per_trace: 5000000
    receiver:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
    storage:
      trace:
        backend: s3
        s3:
          endpoint: minio.observability:9000
          bucket: traces
```

### 6.3 追踪分析查询

```promql
# Prometheus 查询：追踪Volume
# 查看每秒产生的追踪 Span 数
sum(rate(hubble_flows_total[5m])) by (source_namespace)

# 查看网络延迟与追踪延迟的关联
# Grafana: 创建一个 Panel 显示 Hubble Flow 延迟和 Application Span 延迟的对比

# Jaeger 查询：查找特定 TraceID 的完整追踪
# trace_id = "0af7651916cd43dd8448eb211c80319c"

# Tempo 查询：查找丢弃流量相关的追踪
{tags.http.status_code=~"4..|5.."} |= "DROPPED"
```

---

## 7. 高级配置

### 7.1 OTel Collector 高可用配置

```yaml
# 高可用 OTel Collector 配置
apiVersion: opentelemetry.io/v1alpha1
kind: OpenTelemetryCollector
metadata:
  name: cilium-otel-ha
  namespace: kube-system
spec:
  mode: statefulset
  replicas: 3
  config: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317

    processors:
      batch:
        timeout: 1s
        send_batch_size: 1024
      k8sattributes:
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.deployment.name

    exporters:
      otlp/tempo:
        endpoint: tempo.observability:4317
        tls:
          insecure: true

    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [k8sattributes, memory_limiter, batch]
          exporters: [otlp/tempo]
```

### 7.2 采样策略

为减少追踪数据量，配置采样策略：

```yaml
# OTel Collector 采样配置
processors:
  tail_sampling:
    decision_wait: 10s
    policies:
      - name: errors-policy
        type: status_code
        status_code: { status_codes: [ERROR] }
      - name: slow-traces-policy
        type: latency
        latency: { threshold_ms: 1000 }
      - name: probabilistic-policy
        type: probabilistic
        probabilistic: { sampling_percentage: 10 }
      - name: healthy-policy
        type: status_code
        status_code: { status_codes: [OK] }
        combine: { operator: and }
```

### 7.3 TLS 配置

```yaml
# 安全 OTel 传输配置
exporters:
  otlp/tempo:
    endpoint: tempo.observability:4317
    tls:
      insecure: false
      cert_file: /etc/otel/certs/client.crt
      key_file: /etc/otel/certs/client.key
      ca_file: /etc/otel/certs/ca.crt
```

---

## 8. 使用场景

### 8.1 延迟根因分析

```
场景：用户报告 API 响应慢

1. 在 Jaeger/Tempo 中找到慢请求的 Trace
2. 发现应用 Span 显示处理时间 2s
3. 展开 Span 发现网络层 Span 显示 TCP 连接建立 1.5s
4. Hubble Flow 显示跨节点 VXLAN 封装/解封装开销大
5. 根因：网络跨节点延迟过高，需要优化路由或启用 Direct Routing
```

### 8.2 策略变更影响分析

```
场景：部署新 CiliumNetworkPolicy 后部分服务不可访问

1. 在 Tempo 中搜索被拒绝的请求 Trace
2. 发现大量 span.status_code=UNAVAILABLE
3. Hubble Flow 显示 verdict=DROPPED, reason=POLICY_DENIED
4. 对比策略变更前后 Flow 数量变化
5. 定位到新策略错误拒绝了特定 CIDR 范围
```

### 8.3 服务依赖发现

```
场景：需要绘制完整的服务依赖拓扑

1. 从 Tempo 中导出所有 Span 数据
2. 分析 source.service_name 和 target.service_name
3. 使用 Span 关联分析自动生成服务依赖图
4. 发现未记录的直接服务间调用（潜在安全风险）
```

---

## 9. 性能考量

### 9.1 OTel 开销

| 组件                 | 延迟影响 | 资源消耗                |
| :------------------- | :------- | :---------------------- |
| Hubble OTel Exporter | <1ms     | CPU +5%                 |
| OTel Collector       | <5ms     | CPU +10%, Memory +100MB |
| 端到端延迟增加       | 5-10ms   | -                       |

### 9.2 容量规划

```yaml
# 容量规划参考
# 每秒 Flow 数量 → OTel Span 数量
# 10,000 flows/s → ~10,000 spans/s
# 100,000 flows/s → ~100,000 spans/s

# 存储估算（OTLP gRPC, uncompressed）
# 1000 spans/s × 2KB/span × 86400s/day × 7 days = ~1.2TB
```

### 9.3 优化建议

1. **启用采样**：生产环境建议 10-50% 采样率
2. **批量处理**：调整 `send_batch_size` 减少网络调用
3. **异步导出**：使用异步 OTLP 减少阻塞
4. **压缩**：启用 OTLP gzip 压缩

---

## 10. 总结

Hubble 与 OpenTelemetry 的集成将 Cilium 网络可观测性提升到新的层次：

1. **标准化导出**：通过 OTLP 协议支持任意 OTel 兼容后端
2. **网络追踪**：Flow 级别的分布式追踪，无需应用修改
3. **全链路关联**：网络 Span 与应用 Span 共享 TraceID
4. **多后端支持**：Jaeger、Tempo、Zipkin 等任意选择

集成价值：

- **统一可观测性**：网络层 + 应用层统一视图
- **根因分析**：从网络延迟到应用瓶颈的完整链路追踪
- **策略验证**：追踪视角验证网络策略效果
- **容量规划**：基于追踪数据的性能分析

通过 Hubble + OpenTelemetry + Grafana（Tempo/Jaeger），我们实现了云原生环境的**端到端全链路可观测性**，为 Cilium 网络故障排查和性能优化提供了强大工具。
