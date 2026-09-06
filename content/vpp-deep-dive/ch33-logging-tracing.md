---
title: "VPP 深入探讨 ch33：日志、追踪与可观测性"
date: 2026-04-16 10:43:00
tags: [vpp, logging, tracing, observability, prometheus, grafana, telemetry, syslog]
description: "深入解析 VPP 日志与可观测性：日志级别、syslog 集成、Prometheus 导出、Grafana 看板、分布式追踪与性能指标"
---

# VPP 深入探讨 ch33：日志、追踪与可观测性

> [!abstract] 核心要点
> 可观测性是生产运维的关键。本章详解 VPP 日志系统、syslog 集成、Prometheus 指标导出、Grafana 看板配置与分布式追踪实现。

## 1. 日志系统

### 1.1 日志架构

```
┌─────────────────────────────────────────────────────────────┐
│                      VPP 日志系统架构                         │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                    Log Sources                        │   │
│   │                                                      │   │
│   │   ┌──────────┐  ┌──────────┐  ┌──────────┐          │   │
│   │   │  Core    │  │ Plugins  │  │  API     │          │   │
│   │   │  (vlib)  │  │  (NAT,   │  │  (gRPC)  │          │   │
│   │   │          │  │   ACL)   │  │          │          │   │
│   │   └────┬─────┘  └────┬─────┘  └────┬─────┘          │   │
│   │        │             │             │                  │   │
│   └────────┼─────────────┼─────────────┼──────────────────┘   │
│            │             │             │                       │
│            └─────────────┼─────────────┘                       │
│                          │                                     │
│                 ┌────────▼────────┐                            │
│                 │   Log Manager    │                            │
│                 │                  │                            │
│                 │  - Log Level     │                            │
│                 │  - Log Format    │                            │
│                 │  - Rate Limit    │                            │
│                 └────────┬────────┘                            │
│                          │                                     │
│   ┌──────────────────────┼──────────────────────────────┐    │
│   │                      │                              │    │
│   ┌────▼────┐    ┌───────▼────┐    ┌───────▼──────┐     │    │
│   │  File   │    │   Syslog   │    │  Console     │     │    │
│   │(/var/log│    │   (UDP/TCP)│    │  (stdout)    │     │    │
│   │ /vpp/)  │    │             │    │              │     │    │
│   └─────────┘    └─────────────┘    └──────────────┘     │    │
│                                                              │   │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                  Log Levels                          │   │
│   │  EMERG(0) > ALERT(1) > CRIT(2) > ERR(3) >           │   │
│   │  WARN(4) > NOTICE(5) > INFO(6) > DEBUG(7)           │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 日志配置

```bash
# startup.conf 中的日志配置
unix {
    # 日志输出级别
    # 0 = emergency, 1 = alert, 2 = critical, 3 = error
    # 4 = warning, 5 = notice, 6 = info, 7 = debug
    log level notice

    # 日志时间戳格式
    timestamping {

        # 时间戳来源
        # 0 = CLOCK_REALTIME (墙上时间，可调)
        # 1 = CLOCK_MONOTONIC (单调递增)
        clock-type monotonic

        # 时间戳格式
        # 0 = none
        # 1 = with-len (带消息长度)
        # 2 = tick (CPU tick)
        # 3 = short (短格式 HH:MM:SS)
        # 4 = long (完整格式)
        format short
    }

    # 全转储（仅用于调试，生产环境勿用）
    # full-coredump

    # gid (运行组)
    # gid vpp
}

# 插件日志配置
plugins {
    # 插件日志级别覆盖
    plugin default {
        log level warn
    }

    # 特定插件日志
    plugin nat_plugin.so {
        log level debug
    }

    # 禁用插件日志
    plugin acl_plugin.so {
        disable
    }
}
```

### 1.3 Syslog 集成

```bash
# 配置 syslog 输出
unix {
    syslog {
        # 启用 syslog
        enable

        # Syslog facility
        # LOG_LOCAL0 .. LOG_LOCAL7, LOG_DAEMON, LOG_USER
        facility local0

        # 日志级别阈值
        level info

        # 服务名称（用于 syslog 标识）
        service-name vpp

        # 路由选择
        # 0 =轮询, 1 = 每次写入
        routing on

        # 目标服务器（可配置多个）
        # target 192.168.1.100:514
        # target 192.168.1.101:514

        # 传输协议
        # udp (默认) 或 tcp
        proto udp
    }
}

# rsyslog 配置示例 (/etc/rsyslog.d/00-vpp.conf)
$ModLoad imudp
$UDPServerAddress 0.0.0.0
$UDPServerRun 514

# VPP 日志模板
:programname, isequal, "vpp" /var/log/vpp.log
& stop

# 发送到远程日志服务器
:programname, isequal, "vpp" @@remote-logserver:514
& stop
```

### 1.4 日志查看与分析

```bash
# 查看本地日志文件
tail -f /var/log/vpp.log

# 示例输出：
# 2026-04-16 10:30:00.123 [vpp] [info] VPP started
# 2026-04-16 10:30:00.456 [vpp] [info] Initializing plugins
# 2026-04-16 10:30:01.789 [vpp] [warn] Interface TenGigabitEthernet0/0/0: link down
# 2026-04-16 10:30:02.123 [vpp] [error] Buffer allocation failed

# 使用 journalctl 查看
journalctl -u vpp -f

# 日志级别过滤
# 只显示错误及以上级别
grep -E "^\[ERR\]|\[CRIT\]|\[ALERT\]|\[EMERG\]" /var/log/vpp.log

# 时间范围查询
grep "2026-04-16 10:3" /var/log/vpp.log | head -100

# 统计各级别日志数量
awk -F'\\[|\\]' '{print $4}' /var/log/vpp.log | sort | uniq -c
```

## 2. Prometheus 指标导出

### 2.1 Telemetry 架构

```
┌─────────────────────────────────────────────────────────────┐
│                  VPP Prometheus 导出架构                      │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                     VPP                              │   │
│   │   ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │   │
│   │   │   Stats     │  │  Counters   │  │   History   │  │   │
│   │   │   API       │  │             │  │   Buffers   │  │   │
│   │   └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  │   │
│   │          │                │                │          │   │
│   │          └────────────────┼────────────────┘          │   │
│   │                           │                           │   │
│   │                   ┌───────▼───────┐                  │   │
│   │                   │  Exporter     │                  │   │
│   │                   │  (prometheus) │                  │   │
│   │                   └───────┬───────┘                  │   │
│   └───────────────────────────┼──────────────────────────┘   │
│                               │                                │
│                               ↓                                │
│   ┌───────────────────────────────────────────────────────┐   │
│   │              /metrics Endpoint (HTTP)                  │   │
│   │                                                        │   │
│   │  # HELP vpp_interface_rx_packets_total                 │   │
│   │  # TYPE vpp_interface_rx_packets_total counter          │   │
│   │  vpp_interface_rx_packets_total{iface="eth0"} 123456   │   │
│   │                                                        │   │
│   │  # HELP vpp_interface_tx_packets_total                 │   │
│   │  # TYPE vpp_interface_tx_packets_total counter          │   │
│   │  vpp_interface_tx_packets_total{iface="eth0"} 234567   │   │
│   └───────────────────────────────────────────────────────┘   │
│                               │                                │
│                               ↓                                │
│   ┌───────────────────────────────────────────────────────┐   │
│   │                    Prometheus                          │   │
│   │                                                        │   │
│   │   scrape_configs:                                     │   │
│   │     - job_name: 'vpp'                                 │   │
│   │       static_configs:                                 │   │
│   │         - targets: ['localhost:9932']                  │   │
│   └───────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Telemetry 配置

```bash
# startup.conf 中启用 telemetry
telemetry {
    # Telemetry 监听地址
    listen localhost:9932

    # 详细模式（包含更多指标）
    # stats {
    #   polling-interval 1000  # ms
    #   stats-per-node on
    # }
}

# 通过 CLI 查看 telemetry（文本格式）
vppctl telemetry

# 示例输出：
# Thread 0: 0x7f9a4b000
#   node-name: dpdk-input
#  alls: 1234567890
#   叫: 1234567890
#   enqs: 567890123
# Buffer pools:
#   buffers:
#    buffers total: 131072
#    buffers active: 32768
# ...

# 查看 JSON 格式（程序化使用）
vppctl exec "telemetry json"

# 示例输出：
# {
#   "timestamp": 1713258000000,
#   "nodes": [
#     {
#       "name": "dpdk-input",
#       "index": 0,
#       "packets": 1234567890,
#       "cycles": 9876543210
#     }
#   ],
#   "interfaces": [
#     {
#       "name": "TenGigabitEthernet0/0/0",
#       "rx_packets": 1234567890,
#       "rx_bytes": 987654321098,
#       "tx_packets": 2345678901,
#       "tx_bytes": 876543210987
#     }
#   ]
# }
```

### 2.3 Prometheus 配置

```yaml
# prometheus.yml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: "vpp"
    static_configs:
      - targets: ["localhost:9932"]
    metrics_path: /metrics
    scrape_interval: 5s
    scrape_timeout: 5s

  - job_name: "vpp_full"
    static_configs:
      - targets: ["localhost:9932"]
    metrics_path: /metrics_full
    params:
      mode: ["full"]
    scrape_interval: 30s
```

### 2.4 自定义指标导出

```c
// VPP 自定义指标定义

#include <vpp-api/hijack.h>

// 定义计数器
VLIB_HI_JACK_COUNTER(u64, "vpp_custom_packets_total",
    "Total custom packets processed",
    UNITS_PACKETS);

// 定义仪表
VLIB_HI_JACK_GAUGE(u64, "vpp_custom_queue_depth",
    "Current queue depth",
    UNITS_PACKETS);

// 定义直方图
VLIB_HI_JACK_HISTOGRAM(u64, "vpp_custom_latency_seconds",
    "Custom operation latency",
    UNITS_SECONDS,
    {0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1.0, 5.0});

// 使用指标
void
my_plugin_process_packet (vlib_main_t *vm, vlib_buffer_t *b)
{
    // 增加计数器
    VLIB_HI_JACK_COUNTER_INC(vpp_custom_packets_total);

    // 更新仪表
    u32 queue_depth = get_queue_depth();
    VLIB_HI_JACK_GAUGE_SET(vpp_custom_queue_depth, queue_depth);

    // 记录延迟
    u64 start = clib_cpu_time_now();
    do_work(b);
    u64 elapsed = clib_cpu_time_now() - start;
    VLIB_HI_JACK_HISTOGRAM_RECORD(vpp_custom_latency_seconds, elapsed);
}
```

## 3. Grafana 看板

### 3.1 看板变量配置

```json
{
  "dashboard": {
    "title": "VPP Network Performance",
    "uid": "vpp-network-001",
    "version": 1,
    "timezone": "browser",
    "panels": [
      {
        "title": "Interface RX/TX Packets",
        "type": "timeseries",
        "gridPos": { "x": 0, "y": 0, "w": 12, "h": 8 },
        "targets": [
          {
            "expr": "rate(vpp_interface_rx_packets_total[5m])",
            "legendFormat": "{{iface}} RX"
          },
          {
            "expr": "rate(vpp_interface_tx_packets_total[5m])",
            "legendFormat": "{{iface}} TX"
          }
        ]
      }
    ]
  },
  "templating": {
    "list": [
      {
        "name": "instance",
        "type": "query",
        "query": "label_values(vpp_up, instance)",
        "options": []
      },
      {
        "name": "interface",
        "type": "query",
        "query": "label_values(vpp_interface_rx_packets_total{instance=\"$instance\"}, iface)",
        "options": []
      }
    ]
  }
}
```

### 3.2 核心看板面板

```json
{
  "panels": [
    {
      "title": "System Overview",
      "type": "row",
      "gridPos": { "x": 0, "y": 0, "w": 24, "h": 2 },
      "collapsed": false,
      "panels": [
        {
          "title": "CPU Usage",
          "type": "gauge",
          "datasource": "Prometheus",
          "targets": [
            {
              "expr": "rate(vpp_worker_cycles_total[1m]) * 100"
            }
          ],
          "fieldConfig": {
            "defaults": {
              "min": 0,
              "max": 100,
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  { "color": "green", "value": null },
                  { "color": "yellow", "value": 70 },
                  { "color": "red", "value": 90 }
                ]
              }
            }
          }
        },
        {
          "title": "Memory Usage",
          "type": "gauge",
          "targets": [
            {
              "expr": "vpp_memory_used_bytes / vpp_memory_total_bytes * 100"
            }
          ]
        }
      ]
    },
    {
      "title": "Interface Throughput",
      "type": "row",
      "gridPos": { "x": 0, "y": 8, "w": 24, "h": 10 },
      "panels": [
        {
          "title": "RX Packets/s",
          "type": "timeseries",
          "targets": [
            {
              "expr": "rate(vpp_interface_rx_packets_total{iface=~\"$interface\"}[1m]) * 1000",
              "legendFormat": "{{iface}}"
            }
          ],
          "options": {
            "legend": { "displayMode": "table" },
            "tooltip": { "mode": "multi" }
          }
        },
        {
          "title": "TX Packets/s",
          "type": "timeseries",
          "targets": [
            {
              "expr": "rate(vpp_interface_tx_packets_total{iface=~\"$interface\"}[1m]) * 1000"
            }
          ]
        },
        {
          "title": "RX Bytes/s",
          "type": "timeseries",
          "targets": [
            {
              "expr": "rate(vpp_interface_rx_bytes_total{iface=~\"$interface\"}[1m]) * 8 / 1000 / 1000",
              "legendFormat": "{{iface}} Mbps"
            }
          ]
        },
        {
          "title": "TX Bytes/s",
          "type": "timeseries",
          "targets": [
            {
              "expr": "rate(vpp_interface_tx_bytes_total{iface=~\"$interface\"}[1m]) * 8 / 1000 / 1000",
              "legendFormat": "{{iface}} Mbps"
            }
          ]
        }
      ]
    }
  ]
}
```

### 3.3 性能分析面板

```json
{
  "panels": [
    {
      "title": "Node Dispatch Rate",
      "type": "timeseries",
      "targets": [
        {
          "expr": "rate(vpp_node_packets_total[1m])",
          "legendFormat": "{{node}}"
        }
      ],
      "options": {
        "legend": { "displayMode": "table", "placement": "right" }
      }
    },
    {
      "title": "Cycles per Packet by Node",
      "type": "heatmap",
      "targets": [
        {
          "expr": "rate(vpp_node_cycles_total[5m]) / rate(vpp_node_packets_total[5m])",
          "bucketLabel": "node"
        }
      ]
    },
    {
      "title": "Worker Load Distribution",
      "type": "bargauge",
      "targets": [
        {
          "expr": "rate(vpp_worker_cycles_total[1m])",
          "legendFormat": "Worker {{worker}}"
        }
      ],
      "options": {
        "orientation": "horizontal",
        "displayMode": "gradient"
      }
    },
    {
      "title": "Drop Rate",
      "type": "timeseries",
      "targets": [
        {
          "expr": "rate(vpp_interface_drops_total[1m])",
          "legendFormat": "{{iface}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 0.01 },
              { "color": "red", "value": 0.1 }
            ]
          }
        }
      }
    }
  ]
}
```

## 4. 分布式追踪

### 4.1 追踪架构

```
┌─────────────────────────────────────────────────────────────┐
│                  VPP 分布式追踪架构                           │
│                                                              │
│   ┌─────────────┐         ┌─────────────┐         ┌──────┐ │
│   │  Client A   │         │  VPP Router │         │Clnt B│ │
│   │             │         │             │         │      │ │
│   │  trace:1234 │────────▶│  trace:1234 │────────▶│ ...  │ │
│   │  span:A     │         │  span:fw     │         │ span │ │
│   └─────────────┘         └──────┬──────┘         └──────┘ │
│                                  │                          │
│                                  ↓                          │
│   ┌────────────────────────────────────────────────────┐   │
│   │              Trace Context                          │   │
│   │                                                      │   │
│   │  trace_id: abc123 (64-bit)                          │   │
│   │  span_id:  def456 (64-bit)                          │   │
│   │  parent_span_id: ghi789 (可选)                      │   │
│   │  flags: 01 (sampled)                                │   │
│   │                                                      │   │
│   │  传输方式:                                           │   │
│   │  - VLAN 扩展 (VXLAN/GRE)                             │   │
│   │  - gRPC Metadata                                    │   │
│   │  - UDP (OpenTelemetry)                              │   │
│   └────────────────────────────────────────────────────┘   │
│                                  │                          │
│                                  ↓                          │
│   ┌────────────────────────────────────────────────────┐   │
│   │              Trace Collector                        │   │
│   │   Jaeger / Zipkin / OpenTelemetry Collector        │   │
│   └────────────────────────────────────────────────────┘   │
│                                  │                          │
│                                  ↓                          │
│   ┌────────────────────────────────────────────────────┐   │
│   │              Trace Storage                          │   │
│   │   Elasticsearch / Cassandra / In-memory            │   │
│   └────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 VXLAN trace 扩展

```c
// VPP 中 trace context 的 VXLAN 封装

// Trace context header
typedef struct {
    u8  flags;           // bit 0: sampled, bits 1-7: reserved
    u64 trace_id;        // 64-bit trace ID
    u64 span_id;         // 64-bit span ID
    u64 parent_span_id;  // 64-bit parent span ID (optional)
}) __attribute__((packed)) vpp_trace_context_t;

// VXLAN header with trace extension
typedef struct {
    u8  flags;           // 0000_1000 = I bit (valid VNNI)
    u8  reserved1[3];
    u8  flags2;          // Extension bit set
    u8  reserved2;
    u16 vni;             // Virtual Network Identifier
    u8  reserved3;
    u8  next_protocol;   // 0xFF = trace context
    vpp_trace_context_t trace;
}) __attribute__((packed)) vxlan_trace_ext_t;

// 创建带 trace 的 VXLAN 隧道
int
create_traced_vxlan_tunnel (u32 vni, u32 *sw_if_index)
{
    vxlan_params_t params = {
        .is_add = 1,
        .vni = vni,
        .trace_enabled = 1,
        .trace_flags = VPP_TRACE_F_SAMPLED,
    };

    return vxlan_add_del_tunnel(&params, sw_if_index);
}
```

### 4.3 OpenTelemetry 集成

```c
// VPP OpenTelemetry exporter

#include <opentelemetry/api.h>

// OTel 配置
typedef struct {
    u8 enabled;
    char *endpoint;        // "localhost:4317" (gRPC) or "localhost:4318" (HTTP)
    u32 max_batch_size;
    u32 batch_timeout_ns;
    u32 max_queue_size;
    u32 compression;       // 0=none, 1=gzip
} otel_config_t;

// 初始化 OTel exporter
int
otel_init (vlib_main_t *vm, otel_config_t *config)
{
    // 创建 OTLP exporter
    otel_exporter_t *exporter = otel_exporter_create(
        config->endpoint,
        OTEL_EXPORTER_TYPE_GRPC,
        NULL  // credentials
    );

    // 配置批量处理器
    otel_processor_t *processor = otel_batch_processor_create(
        exporter,
        config->max_batch_size,
        config->batch_timeout_ns,
        config->max_queue_size
    );

    // 注册 tracer provider
    otel_provider_t *provider = otel_provider_create(
        processor,
        "vpp-router",
        NULL  // resource attributes
    );

    otel_set_provider(provider);

    return 0;
}

// 创建 span
otel_span_t *
otel_start_span (u64 trace_id, u64 span_id, char *name)
{
    otel_span_start_args_t args = {
        .trace_id = trace_id,
        .span_id = span_id,
        .name = name,
        .start_time_ns = clib_cpu_time_now(),
    };

    return otel_span_start(&args);
}

// 记录属性
void
otel_span_set_attribute (otel_span_t *span, char *key, u64 value)
{
    otel_span_set_attribute_i64(span, key, value);
}

// 记录事件
void
otel_span_add_event (otel_span_t *span, char *name)
{
    otel_span_event_t event = {
        .name = name,
        .timestamp_ns = clib_cpu_time_now(),
    };

    otel_span_add_event(span, &event);
}

// 结束 span
void
otel_end_span (otel_span_t *span)
{
    span->end_time_ns = clib_cpu_time_now();
    otel_span_end(span);
}
```

### 4.4 追踪配置

```bash
# startup.conf 中配置分布式追踪
telemetry {
    # OpenTelemetry 配置
    otel {
        # 启用追踪
        enable

        # Collector 端点
        endpoint localhost:4317

        # 采样率 (0.0 - 1.0)
        sampling-rate 0.1

        # 最大批量大小
        max-batch-size 1024

        # 压缩方式
        compression gzip
    }

    # Jaeger 配置（替代方案）
    jaeger {
        enable
        agent-endpoint localhost:6831
        collector-endpoint localhost:14268
        service-name vpp-router
    }
}

# 运行时启用/禁用追踪
vppctl set trace otel enable
vppctl set trace otel disable

# 设置采样率
vppctl set trace otel sampling-rate 0.5

# 查看追踪统计
vppctl show trace otel

# 示例输出：
# OpenTelemetry Status:
#   Enabled: yes
#   Endpoint: localhost:4317
#   Sampling rate: 0.1
#   Total spans: 1234567
#   Exported spans: 123456
#   Dropped spans: 11
#   Queue size: 1024/8192
```

## 5. 日志分析实践

### 5.1 ELK Stack 集成

```bash
# Filebeat 配置 (/etc/filebeat/filebeat.yml)
filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/vpp/*.log
    json.keys_under_root: true
    json.add_error_key: true
    fields:
      service: vpp
      type: vpp-log
    fields_under_root: true

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "vpp-%{+yyyy.MM.dd}"

# Logstash 配置 (/etc/logstash/conf.d/vpp.conf)
input {
  beats {
    port => 5044
  }
}

filter {
  if [type] == "vpp-log" {
    grok {
      match => {
        "message" => "%{TIMESTAMP_ISO8601:timestamp} \[%{DATA:program}\] \[%{LOGLEVEL:level}\] %{GREEDYDATA:details}"
      }
    }
    date {
      match => ["timestamp", "ISO8601"]
      target => "@timestamp"
    }
  }
}

output {
  elasticsearch {
    hosts => ["elasticsearch:9200"]
    index => "vpp-%{+YYYY.MM.dd}"
  }
}
```

### 5.2 日志异常检测

```bash
#!/bin/bash
# vpp_log_anomaly_detect.sh - 日志异常检测

LOG_FILE="/var/log/vpp.log"
ALERT_EMAIL="admin@example.com"

# 异常模式定义
declare -A ANOMALY_PATTERNS=(
    ["error"]="\[ERR\]|\[CRIT\]"
    ["warning"]="\[WARN\]"
    ["drop"]="drops: [0-9]+"
    ["memory"]="memory.*(low|critical|failed)"
    ["buffer"]="buffer.*(exhaust|failed)"
)

# 检测函数
detect_anomalies() {
    local severity=$1
    local pattern=${ANOMALY_PATTERNS[$severity]}
    local count

    count=$(grep -cE "$pattern" "$LOG_FILE" 2>/dev/null || echo 0)

    if [ "$count" -gt 0 ]; then
        echo "[$severity] Found $count matches for pattern: $pattern"

        # 获取最近的匹配项
        echo "Recent matches:"
        grep -E "$pattern" "$LOG_FILE" | tail -5

        return 1
    fi

    return 0
}

# 主检测逻辑
echo "VPP Log Anomaly Detection"
echo "========================"
echo "Time: $(date)"
echo ""

anomalies=0

for severity in error warning drop memory buffer; do
    if ! detect_anomalies "$severity"; then
        ((anomalies++))
    fi
done

if [ $anomalies -gt 0 ]; then
    echo ""
    echo "ALERT: $anomalies anomaly type(s) detected!"

    # 发送告警邮件
    # mail -s "[VPP ALERT] Anomalies detected" "$ALERT_EMAIL" < /tmp/vpp_anomaly_report.txt
else
    echo "No anomalies detected."
fi
```

### 5.3 性能趋势分析

```python
#!/usr/bin/env python3
"""VPP 性能趋势分析"""

import json
import time
from prometheus_client import PrometheusClient

class VPPTrendAnalyzer:
    def __init__(self, prometheus_url="http://localhost:9090"):
        self.client = PrometheusClient(prometheus_url)

    def collect_metrics(self, duration=300):
        """收集指定时段的指标"""
        end_time = time.time()
        start_time = end_time - duration

        # 收集关键指标
        metrics = {
            "cpu_usage": self.query_range(
                "rate(vpp_worker_cycles_total[1m])",
                start_time, end_time
            ),
            "rx_packets": self.query_range(
                "rate(vpp_interface_rx_packets_total[1m])",
                start_time, end_time
            ),
            "tx_packets": self.query_range(
                "rate(vpp_interface_tx_packets_total[1m])",
                start_time, end_time
            ),
            "drops": self.query_range(
                "rate(vpp_interface_drops_total[1m])",
                start_time, end_time
            )
        }

        return metrics

    def detect_anomalies(self, metrics):
        """检测异常"""
        anomalies = []

        # 检测 CPU 峰值
        cpu_values = [p[1] for p in metrics["cpu_usage"]]
        cpu_avg = sum(cpu_values) / len(cpu_values)
        cpu_max = max(cpu_values)

        if cpu_max > cpu_avg * 2:
            anomalies.append({
                "type": "cpu_spike",
                "message": f"CPU spike detected: max={cpu_max}, avg={cpu_avg}",
                "severity": "warning"
            })

        # 检测丢包
        drop_values = [p[1] for p in metrics["drops"]]
        if sum(drop_values) > 0:
            anomalies.append({
                "type": "packet_drops",
                "message": f"Packet drops detected: {sum(drop_values)} total",
                "severity": "critical"
            })

        return anomalies

    def generate_report(self, metrics, anomalies):
        """生成分析报告"""
        report = {
            "timestamp": time.time(),
            "duration_seconds": 300,
            "metrics_summary": {},
            "anomalies": anomalies
        }

        # 计算各指标统计
        for name, values in metrics.items():
            if values:
                numeric_values = [v[1] for v in values]
                report["metrics_summary"][name] = {
                    "min": min(numeric_values),
                    "max": max(numeric_values),
                    "avg": sum(numeric_values) / len(numeric_values)
                }

        return report

if __name__ == "__main__":
    analyzer = VPPTrendAnalyzer()

    print("Collecting VPP metrics...")
    metrics = analyzer.collect_metrics(duration=300)

    print("Detecting anomalies...")
    anomalies = analyzer.detect_anomalies(metrics)

    print("Generating report...")
    report = analyzer.generate_report(metrics, anomalies)

    print(json.dumps(report, indent=2))
```
