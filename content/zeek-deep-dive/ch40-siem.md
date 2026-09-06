---
title: "Zeek 深度探索 (四十)：SIEM 集成"
date: 2026-04-15
tags:
  - zeek
  - series
  - siem
  - elasticsearch
  - splunk
  - chronicle
  - logging
  - elk
description: "深入解析 Zeek SIEM 集成——Elasticsearch、Splunk、Google Chronicle 配置、日志导入、Kibana 可视化、SPL 查询、威胁检测规则"
---

> [!info] Zeek 2026 深度探索系列 0. [[zeek-deep-dive|全栈学习路径总览]]
> ... 39. [[ch39-hunting|第三十九章：威胁狩猎]] 40. **第四十章：SIEM 集成**

---

## 1. SIEM 集成概述

SIEM（Security Information and Event Management）是**安全日志集中分析平台**，Zeek 通过 EVE-JSON 输出与其无缝集成。

```
┌─────────────────────────────────────────────────────────────┐
│                 Zeek SIEM 集成架构                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   ┌─────────┐                                              │
│   │  Zeek  │──▶ EVE-JSON ──▶ Filebeat ──▶ Elasticsearch    │
│   └─────────┘                           │                  │
│                                          ▼                  │
│                                   ┌──────────────┐         │
│                                   │ Kibana       │         │
│                                   │ Visualize    │         │
│                                   └──────────────┘         │
│                                                             │
│   ┌─────────┐                                              │
│   │ Zeek   │──▶ Syslog ──▶ RSyslog ──▶ Logstash          │
│   └─────────┘                           │                  │
│                                          ▼                  │
│                                   ┌──────────────┐         │
│                                   │ Splunk       │         │
│                                   │ SIEM         │         │
│                                   └──────────────┘         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 常见集成方式

| 方式           | 协议     | 优点         | 缺点            |
| :------------- | :------- | :----------- | :-------------- |
| **Filebeat**   | 文件读取 | 简单、无侵入 | 有延迟          |
| **Kafka**      | 消息队列 | 解耦、高吞吐 | 需要 Kafka 集群 |
| **Syslog**     | UDP/TCP  | 通用兼容     | 丢包风险        |
| **Direct**     | HTTP API | 实时         | 需要应用适配    |
| **Zeek Agent** | 插件     | 完整数据     | 需要部署代理    |

---

## 2. Elasticsearch 集成

### 2.1 Elasticsearch 概述

Elasticsearch 是基于 Lucene 的**分布式搜索和分析引擎**，配合 Logstash（采集）和 Kibana（可视化）构成 ELK Stack。

### 2.2 Zeek EVE 输出配置

```zeek
# /usr/local/zeek/share/zeek/site/elasticsearch.zeek

@load base/frameworks/logging

# 使用 JSON 格式输出
redef Log::default_writer = Log::EVE_JSON;
redef Log::timestamp_format = "ISO8601";

# 输出目录（Filebeat 会读取此目录）
redef Log::default_log_dir = "/var/log/zeek/eve";

# 为每个日志流创建 EVE 过滤器
event zeek_init() {
    local streams = set(
        HTTP::LOG, DNS::LOG, SSL::LOG, SSH::LOG,
        SMTP::LOG, CONN::LOG, FILES::LOG, NOTICE::LOG
    );

    for ( id in streams ) {
        Log::add_filter(id, [
            $name="elasticsearch",
            $path=fmt("eve-%s", id),
            $writer=Log::EVE_JSON
        ]);
    }
}
```

### 2.3 Filebeat 配置

```yaml
# /etc/filebeat/filebeat.yml

filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/zeek/eve/*.json
    json.keys_under_root: true
    json.add_error_key: true
    json.message_key: log

    # 字段重命名
    fields:
      log_type: zeek
      env: production
    fields_under_root: false

    # 多行处理（EVE JSON 每行一条）
    multiline.type: pattern
    multiline.pattern: '^\{'
    multiline.negate: true
    multiline.match: after

# =================== 输出到 Elasticsearch ===================
output.elasticsearch:
  hosts: ["elasticsearch:9200"]

  # 索引模板
  index: "zeek-%{+yyyy.MM.dd}"

  # 认证
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"

  # ILM 策略
  ilm.enabled: true
  ilm.rollover_alias: "zeek"
  ilm.pattern: "{now/d}-000001"
  ilm.policy_name: "zeek-policy"

# =================== 索引模板 ===================
setup.template:
  name: "zeek"
  pattern: "zeek-*"
  settings:
    index:
      number_of_shards: 1
      number_of_replicas: 1
  mappings:
    dynamic: true
    properties:
      timestamp:
        type: date
      event_type:
        type: keyword
      src_ip:
        type: ip
      dest_ip:
        type: ip
      src_port:
        type: integer
      dest_port:
        type: integer
```

### 2.4 Elasticsearch 索引模板

```bash
# 创建 Zeek 专用索引模板
curl -X PUT "elasticsearch:9200/_index_template/zeek" \
  -u elastic:${ELASTIC_PASSWORD} \
  -H 'Content-Type: application/json' \
  -d'
{
  "index_patterns": ["zeek-*"],
  "template": {
    "settings": {
      "number_of_shards": 1,
      "number_of_replicas": 1,
      "index.lifecycle.name": "zeek-policy"
    },
    "mappings": {
      "dynamic": "true",
      "properties": {
        "timestamp": { "type": "date" },
        "event_type": { "type": "keyword" },
        "src_ip": { "type": "ip" },
        "dest_ip": { "type": "ip" },
        "src_port": { "type": "integer" },
        "dest_port": { "type": "integer" },
        "proto": { "type": "keyword" },
        "app_proto": { "type": "keyword" },
        "uid": { "type": "keyword" },
        "zeek": {
          "type": "object",
          "dynamic": true
        }
      }
    }
  }
}'
```

### 2.5 Kibana 可视化

#### 2.5.1 索引模式配置

```bash
# 在 Kibana 中创建索引模式
# Management > Stack Management > Index Patterns > Create index pattern
# Pattern: zeek-*
# Time field: timestamp
```

#### 2.5.2 预定义可视化

**连接统计 Dashboard**：

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek Connection Overview                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                 │
│  │ Total Conn      │  │ Active Conn     │                 │
│  │ 1,234,567       │  │ 12,345          │                 │
│  └─────────────────┘  └─────────────────┘                 │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐  │
│  │            Connection Timeline                       │  │
│  │  ~~~~~\_________________________/~~~~~~~~            │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌─────────────────┐  ┌─────────────────┐                 │
│  │ Top Dest IPs   │  │ Protocol Dist   │                 │
│  │ 1. 8.8.8.8     │  │ TCP   ████ 80%  │                 │
│  │ 2. 1.1.1.1     │  │ UDP   ██  15%  │                 │
│  │ 3. 93.184...   │  │ ICMP  █   5%   │                 │
│  └─────────────────┘  └─────────────────┘                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Kibana Lens 查询示例**：

```
# HTTP 流量分析
GET zeek-*/_search
{
  "query": {
    "bool": {
      "filter": [
        { "term": { "event_type": "http" } },
        { "range": { "timestamp": { "gte": "now-1h" } } }
      ]
    }
  },
  "aggs": {
    "top_hosts": {
      "terms": { "field": "zeek.host", "size": 10 }
    },
    "status_codes": {
      "terms": { "field": "zeek.status_code" }
    }
  }
}
```

---

## 3. Splunk 集成

### 3.1 Splunk 概述

Splunk 是企业级 **SIEM 和日志管理平台**，使用 SPL（Splunk Processing Language）进行查询。

### 3.2 Zeek 日志输出到 Splunk

#### 3.2.1 直接 HTTP 输出

```zeek
# /usr/local/zeek/share/zeek/site/splunk-hec.zeek

@load base/frameworks/logging

# Splunk HTTP Event Collector (HEC) 输出
# 需要在 Splunk 中配置 HEC token

redef Log::default_writer = Log::EVE_JSON;

# 自定义 HEC 输出脚本
event Log::write(rec: Log::ID, path: string, num_lines: count) {
    # 读取日志文件并发送到 HEC
    local log_file = fmt("%s/%s.json", Log::default_log_dir, path);
    local content = cat(log_file);

    # 调用 HEC API
    local payload = fmt('{"event": %s}', content);
    SplunkHEC::send(payload);
}
```

#### 3.2.2 Splunk Forwarder 配置

```bash
# /opt/splunkforwarder/etc/system/local/inputs.conf

[monitor:///var/log/zeek]
disabled = false
followTail = 0
index = zeek
sourcetype = zeek:json

[monitor:///var/log/zeek/eve]
disabled = false
index = zeek
sourcetype = zeek:eve
```

```bash
# /opt/splunkforwarder/etc/system/local/props.conf

[zeek:json]
DATETIME_CONFIG =
INDEXED_EXTRACTIONS = json
KV_MODE = json
TIME_PREFIX = "\"timestamp\":"
TIME_FORMAT = %Y-%m-%dT%H:%M:%S.%LZ
```

### 3.3 SPL 查询示例

#### 3.3.1 基础查询

```spl
# 查看所有 Zeek 日志
index=zeek sourcetype=zeek:eve

# 查看 HTTP 日志
index=zeek event_type=http

# 按源 IP 统计连接数
index=zeek event_type=conn | stats count by src_ip

# 查看 Top 10 目标域名
index=zeek event_type=dns | top limit=10 zeek.query
```

#### 3.3.2 威胁检测查询

```spl
# 检测 DNS 隧道（大量 TXT 查询）
index=zeek event_type=dns zeek.qtype=TXT
| stats count by src_ip
| where count > 100

# 检测可疑 HTTP User-Agent
index=zeek event_type=http
| search zeek.user_agent IN ("python-requests*", "Masscan", "nmap")
| stats count by src_ip, zeek.user_agent

# 检测内部服务器直连外部
index=zeek event_type=conn
| where like(src_ip, "10.%") AND NOT like(dest_ip, "10.%")
| stats sum(zeek.orig_bytes) as total_bytes by src_ip
| where total_bytes > 10000000
```

#### 3.3.3 关联分析

```spl
# 关联 DNS 和 HTTP（DNS 查询后有 HTTP 访问）
index=zeek
| join type=inner unixtime
    [search index=zeek event_type=dns
     | rename zeek.query as domain
     | fields src_ip, domain, timestamp]
    [search index=zeek event_type=http
     | rename zeek.host as domain
     | fields src_ip, domain, timestamp]
| where relative_time(timestamp, "-5m") <= relative_time(timestamp, "+5m")
| table src_ip, domain
```

### 3.4 Splunk 告警配置

```spl
# 保存为告警：检测大规模扫描
index=zeek event_type=conn
| stats dc(dest_ip) as unique_targets by src_ip
| where unique_targets > 50
| `ring`("Potential port scan from {src_ip} to {unique_targets} hosts", mail)

# 保存为告警：检测数据外泄
index=zeek event_type=conn
| where zeek.orig_bytes > 100000000
| `ring`("Large data transfer from {src_ip}", mail)
```

### 3.5 Splunk Dashboard

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek Security Dashboard                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Time Range: Last 24 hours    [Export] [Refresh ▼]         │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Security Overview                                    │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │  │
│  │  │ Alerts   │  │ Top Src  │  │ Top Dest │           │  │
│  │  │ 123      │  │ 192.168  │  │ 8.8.8.8  │           │  │
│  │  └──────────┘  └──────────┘  └──────────┘           │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Connection Timeline                                  │  │
│  │  ████                                                   │  │
│  │  ████████████                                           │  │
│  │  ████████████████                                       │  │
│  └──────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌─────────────────────┐  ┌─────────────────────────────┐  │
│  │ Protocol Distribution│  │ Top HTTP Hosts              │  │
│  │ TCP ████████ 80%    │  │ 1. api.example.com         │  │
│  │ UDP ██ 15%          │  │ 2. www.google.com           │  │
│  │ ICMP █ 5%          │  │ 3. login.microsoft.com      │  │
│  └─────────────────────┘  └─────────────────────────────┘  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 4. Google Chronicle 集成

### 4.1 Chronicle 概述

Google Chronicle 是**云原生 SIEM**，支持无限日志摄取和快速搜索，使用 YARA-L 规则进行检测。

### 4.2 Zeek 日志转发到 Chronicle

#### 4.2.1 支持的协议

| 方式              | 说明                |
| :---------------- | :------------------ |
| **Syslog**        | 通过 RSyslog 转发   |
| **Cloud Pub/Sub** | 发布到 Google Cloud |
| **Backstory**     | Chronicle 原生采集  |

#### 4.2.2 Syslog 转发配置

```bash
# /etc/rsyslog.d/zeek-chronicle.conf

# Zeek JSON 日志转发到 Chronicle
module(load="omrelp")

# 连接 Chronicle Ingestion API
*.* action(type="omrelp"
           target="ingestion.backstory.google.com"
           port="6514"
           tls="on"
           tls.caCert="/etc/ssl/certs/chronicle-ca.pem"
           tls.authCert="/etc/ssl/certs/chronicle-cert.pem"
           tls.authMode="anon")
```

#### 4.2.3 Pub/Sub 集成

```bash
# 创建 Pub/Sub topic
gcloud pubsub topics create zeek-logs

# 配置 Zeek 输出
@load base/frameworks/logging
redef Log::default_writer = Log::EVE_JSON;
redef Log::default_log_dir = "/var/log/zeek/eve";

# 使用 google-pubsub-gateway
# 参考: https://github.com/google/chronicle-backstory-chronicle-forwarder
```

### 4.3 Chronicle 日志格式

Chronicle 支持 **Raw Log Format**：

```json
{
  "logType": "ZEek_CONN",
  "timestamp": "2026-04-15T10:30:00.123Z",
  "description": "Zeek connection log",
  "source": "zeek-sensor-01",
  "data": {
    "uid": "ChhnUs4ev9k2",
    "src_ip": "192.168.1.100",
    "src_port": 54321,
    "dest_ip": "93.184.216.34",
    "dest_port": 443,
    "proto": "tcp",
    "service": "ssl",
    "duration": 12.345,
    "orig_bytes": 1234,
    "resp_bytes": 5678
  }
}
```

### 4.4 Chronicle 搜索

#### 4.4.1 UDM 搜索

```spl
// Chronicle Insight 搜索语法

// 查找可疑连接
metadata.event_type = "NETWORK_CONNECTION"
AND principal.ip = "192.168.1.100"
AND target.ip = "93.184.216.34"

// 查找 DNS 查询
metadata.event_type = "DNS"
AND target.name = "*.evil.com"

// 查找恶意软件通信
metadata.event_type = "NETWORK_CONNECTION"
AND target.port = 443
AND target.application_protocol = "http"
```

#### 4.4.2 YARA-L 检测规则

```yaml
# rule.yaral

rule ZeekDNSTunneling {
  meta:
    description = "Detect potential DNS tunneling"
    severity = "HIGH"

  events:
    $dns = zeek.dns.event_type = "dns"

    $query = zeek.dns.query.length > 50

  condition:
    $dns and $query
}

rule ZeekHTTPSuspiciousURI {
  meta:
    description = "Detect suspicious HTTP URI"
    severity = "MEDIUM"

  events:
    $http = zeek.http.event_type = "http"

    $uri = zeek.http.uri.length > 500

  condition:
    $http and $uri
}
```

---

## 5. 其他 SIEM 集成

### 5.1 QRadar 集成

```bash
# /etc/rsyslog.d/zeek-qradar.conf

# 转发到 QRadar via Syslog
*.* @@qradar.example.com:514

# 使用 Log Stsource 协议
module(load="omfwd")
*.* action(type="omfwd"
           target="qradar.example.com"
           port="514"
           protocol="tcp"
           template="ZEekFormat")
```

```bash
# 定义 QRadar 日志格式
$template ZEekFormat,"%msg%\n"
```

### 5.2 Humio 集成

```yaml
# Humio 配置文件

sources:
  - name: zeek
    type: file
    path: /var/log/zeek/eve/*.json
    ingestListener: https://cloud.humio.com:443
    parser: json
    tags:
      product: zeek
      env: production
```

### 5.3 Grafana Loki 集成

```yaml
# Promtail 配置（/etc/promtail/config.yml）

server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: zeek
    static_configs:
      - targets:
          - localhost
        labels:
          job: zeek
          __path__: /var/log/zeek/eve/*.json
```

---

## 6. 高可用集成架构

### 6.1 多节点负载均衡

```
┌─────────────────────────────────────────────────────────────┐
│                 高可用 SIEM 集成架构                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Zeek Cluster                                             │
│   ┌─────────┐  ┌─────────┐  ┌─────────┐                  │
│   │ Worker 1│  │ Worker 2│  │ Worker 3│                  │
│   └────┬────┘  └────┬────┘  └────┬────┘                  │
│        │             │             │                        │
│        └─────────────┼─────────────┘                        │
│                      ▼                                      │
│              ┌──────────────┐                              │
│              │   Kafka      │                              │
│              │  (message)    │                              │
│              └──────┬───────┘                              │
│                     │                                        │
│         ┌───────────┼───────────┐                          │
│         ▼           ▼           ▼                          │
│   ┌──────────┐ ┌──────────┐ ┌──────────┐                │
│   │Filebeat 1│ │Filebeat 2│ │Filebeat 3│                │
│   └────┬─────┘ └────┬─────┘ └────┬─────┘                │
│        │             │             │                        │
│        └─────────────┼─────────────┘                        │
│                      ▼                                      │
│              ┌──────────────┐                              │
│              │Elasticsearch│                              │
│              │  Cluster     │                              │
│              └──────────────┘                              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 Kafka 集成

```bash
# /usr/local/zeek/share/zeek/site/kafka.zeek

@load policy/frameworks/logging/writers/kafka

# Kafka 配置
redef Kafka::logging_kafka_topic = "zeek-logs";
redef Kafka::logging_kafka_brokers = set(
    "kafka1:9092",
    "kafka2:9092",
    "kafka3:9092"
);

# 使用 JSON 格式
redef Kafka::json_timestamps = "ISO8601";

# 批量发送
redef Kafka::max_batch_size = 1000;
redef Kafka::max_batch_duration = 1sec;
```

### 6.3 日志缓冲配置

```bash
# /etc/systemd/system/zeek.service.d/log-buffer.conf

[Service]
# 增加日志缓冲区
Environment="ZEEK_LOG_BUFFER_SIZE=16384"

# 限制日志写入延迟
Environment="ZEEK_LOG_FLUSH_INTERVAL=1s"
```

---

## 7. 性能优化

### 7.1 Filebeat 优化

```yaml
# /etc/filebeat/filebeat.yml (优化版)

filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/zeek/eve/*.json

    # 读取优化
    close_inactive: 5m
    harvester_buffer_size: 16384

    # JSON 处理优化
    json.keys_under_root: true
    json.add_error_key: true

    # 多行配置
    multiline.type: pattern
    multiline.pattern: '^\{'
    multiline.negate: true
    multiline.match: after

# 队列优化
queue.mem:
  events: 4096
  flush.min_events: 512
  flush.timeout: 1s

# 输出优化
output.elasticsearch:
  bulk_max_size: 4096
  worker: 2
  compression_level: 3
```

### 7.2 Elasticsearch 优化

```bash
# 更新索引模板
curl -X PUT "elasticsearch:9200/_index_template/zeek" \
  -H 'Content-Type: application/json' \
  -d'
{
  "index_patterns": ["zeek-*"],
  "template": {
    "settings": {
      "number_of_shards": 3,
      "number_of_replicas": 1,
      "index.refresh_interval": "5s",
      "index.translog.durability": "async",
      "index.translog.sync_interval": "5s"
    }
  }
}'
```

### 7.3 监控配置

```yaml
# filebeat 监控
monitoring:
  enabled: true
  elasticsearch:
    enabled: true
    hosts: ["elasticsearch:9200"]

# elasticsearch 监控
monitoring:
  cluster:
    alerts:
      enabled: true
```

---

## 8. 故障排除

### 8.1 常见问题

| 问题                   | 原因              | 解决方案                             |
| :--------------------- | :---------------- | :----------------------------------- |
| Filebeat 无法读取日志  | 权限问题          | `chmod 644 /var/log/zeek/eve/*.json` |
| Elasticsearch 索引失败 | 映射冲突          | 更新索引模板                         |
| 日志延迟高             | Filebeat 批量太小 | 增加 `bulk_max_size`                 |
| 丢失日志               | Kafka 消费者落后  | 增加消费者数量                       |
| Splunk 解析失败        | Sourcetype 不匹配 | 检查 `props.conf`                    |

### 8.2 验证命令

```bash
# 验证 Filebeat 配置
filebeat test config -c /etc/filebeat/filebeat.yml

# 验证 Elasticsearch 连接
curl -X GET "elasticsearch:9200/_cluster/health?pretty"

# 验证 Splunk HEC
curl -k https://splunk:8088/services/collector/health

# 检查日志流
tail -f /var/log/zeek/eve/conn.json | jq .
```

---

## 9. 完整配置示例

### 9.1 Zeek 输出配置

```zeek
# /usr/local/zeek/share/zeek/site/siem-integration.zeek

@load base/frameworks/logging

# =================== 输出格式 ===================
redef Log::default_writer = Log::EVE_JSON;
redef Log::timestamp_format = "ISO8601";
redef Log::use_utc = T;
redef Log::include_unset_fields = F;

# =================== 输出路径 ===================
redef Log::default_log_dir = "/var/log/zeek/eve";

# =================== 日志过滤（可选）===================
event zeek_init() {
    # 选择性输出到 SIEM
    local siem_streams = set(
        CONN::LOG,
        HTTP::LOG,
        DNS::LOG,
        SSL::LOG,
        SSH::LOG,
        SMTP::LOG,
        NOTICE::LOG
    );

    for ( id in siem_streams ) {
        Log::add_filter(id, [
            $name="siem",
            $path=fmt("siem-%s", id),
            $writer=Log::EVE_JSON
        ]);
    }
}
```

### 9.2 Filebeat 配置

```yaml
# /etc/filebeat/filebeat.yml

filebeat.inputs:
  - type: log
    enabled: true
    paths:
      - /var/log/zeek/eve/siem-*.json
    json.keys_under_root: true
    json.add_error_key: true
    fields:
      product: zeek
      log_type: security
    fields_under_root: true

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "zeek-siem-%{+yyyy.MM.dd}"
  username: "elastic"
  password: "${ELASTIC_PASSWORD}"

setup.template.name: "zeek-siem"
setup.template.pattern: "zeek-siem-*"
setup.template.settings:
  index.number_of_shards: 2
  index.number_of_replicas: 1
```

### 9.3 Kibana Dashboard 导入

```bash
# 导出 Dashboard JSON
curl -X GET "elasticsearch:9200/_dashboards" \
  -u elastic:${ELASTIC_PASSWORD} \
  > zeek-dashboards.ndjson

# 导入 Dashboard
curl -X POST "elasticsearch:9200/_dashboards/_import" \
  -u elastic:${ELASTIC_PASSWORD} \
  -H "Content-Type: application/json" \
  --data-binary @zeek-dashboards.ndjson
```

---

## 总结

Zeek 与主流 SIEM 平台的集成本章涵盖：

1. **Elasticsearch/ELK**：Filebeat 采集 + EVE JSON + Kibana 可视化
2. **Splunk**：Universal Forwarder 或 HEC + SPL 查询 + Dashboard
3. **Google Chronicle**：Syslog/Pubsub + YARA-L 检测规则
4. **其他**：QRadar、Humio、Grafana Loki 等

关键配置要点：

- 使用 EVE_JSON writer 实现格式统一
- Filebeat/Kafka 作为高吞吐量的中转层
- 根据 SIEM 要求调整索引模板和字段映射
- 配置监控确保日志流健康
