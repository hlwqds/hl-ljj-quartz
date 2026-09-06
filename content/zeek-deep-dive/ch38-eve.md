---
title: "Zeek 深度探索 (三十八)：EVE 格式"
date: 2026-04-15
tags:
  - zeek
  - series
  - logging
  - eve-json
  - json
  - suricata
  - log-format
description: "深入解析 Zeek EVE-JSON 格式——与 Suricata EVE 格式对比、字段映射、日志归一化、timestamp 同步、多格式输出配置"
---

> [!info] Zeek 2026 深度探索系列 0. [[zeek-deep-dive|全栈学习路径总览]]
> ... 37. [[ch37-tuning|第三十七章：Tuning 清单]] 38. **第三十八章：EVE 格式** 39. [[ch39-hunting|第三十九章：威胁狩猎]] 40. [[ch40-siem|第四十章：SIEM 集成]]

---

## 1. EVE-JSON 格式概述

EVE（Extensible Event Format）是 Zeek 和 Suricata 共用的**统一日志 JSON 格式**规范，旨在解决不同 NSM 工具间日志格式不一致的问题。Zeek 自 5.0+ 版本增强了 EVE 兼容支持。

### 1.1 EVE 格式核心设计

```
┌─────────────────────────────────────────────────────────────┐
│                    EVE-JSON Event                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  {                                                         │
│    "timestamp": "2026-04-15T10:30:00.123456Z",             │
│    "event_type": "conn",          ← 事件类型标识            │
│    "src_ip": "192.168.1.100",     ← 归一化字段             │
│    "src_port": 54321,                                      │
│    "dest_ip": "93.184.216.34",                            │
│    "dest_port": 443,                                       │
│    "proto": "tcp",                                         │
│    "app_proto": "http",            ← 应用层协议             │
│    "zeek": {                       ← Zeek 特定数据         │
│      "uid": "ChhnUs4ev9k2",                               │
│      "conn_state": "SF",                                   │
│      "duration": 12.345,                                   │
│      "orig_bytes": 1234,                                   │
│      "resp_bytes": 5678                                    │
│    }                                                       │
│  }                                                         │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 EVE 与 Suricata EVE 的关系

EVE 格式最初由 Suricata 提出并推广，Zeek 在 5.0+ 版本中增加了 `EVE_JSON` writer 以实现格式兼容。

| 特性       | Suricata EVE                 | Zeek EVE                    |
| :--------- | :--------------------------- | :-------------------------- |
| 标准化程度 | 原生 EVE                     | 通过 `EVE_JSON` writer 兼容 |
| 事件类型   | `event_type` 字段区分        | 同 Suricata                 |
| 归一化字段 | `src_ip/dest_ip` 等          | 同 Suricata                 |
| 原始数据   | 嵌入 `alert`/`http` 等子对象 | 嵌入 `zeek` 子对象          |
| 输出方式   | 单文件多事件流               | 单文件多事件流              |

---

## 2. Zeek EVE_JSON Writer

### 2.1 启用 EVE 输出

```zeek
# /usr/local/zeek/share/zeek/site/eve.zeek

@load base/frameworks/logging

# 使用 EVE_JSON writer
redef Log::default_writer = Log::EVE_JSON;

# EVE 输出路径
redef Log::default_log_dir = "/var/log/zeek/eve";

# 启用所有日志流
event zeek_init() {
    for ( id in Log::active_streams() ) {
        Log::add_filter(id, [
            $name="eve",
            $path=fmt("eve-%s", id),
            $writer=Log::EVE_JSON
        ]);
    }
}
```

### 2.2 配置参数

```zeek
# /usr/local/zeek/share/zeek/site/eve-config.zeek

# =================== EVE 格式配置 ===================

# 时间戳格式（ISO8601）
redef Log::timestamp_format = "ISO8601";

# 使用 Unix 时间戳（与 Suricata 一致）
# redef Log::timestamp_format = "UNIX";

# JSON 紧凑输出
redef Log::JSON_Separators = {" ", ""};

# 包含空字段
redef Log::include_unset_fields = F;

# 写入缓冲
redef Log::write_buffer_size = 8192;

# =================== EVE 字段配置 ===================

# 包含元数据
redef Log::log_zeek_version = T;
redef Log::log_hostname = F;

# 流式写入（非阻塞）
redef Log::log_asynchronous = T;
```

### 2.3 完整配置示例

```ini
# /usr/local/zeek/etc/zeekctl.cfg

[logging]
logdir = /var/log/zeek/eve
rotation_format = eve
use_compression = true
```

---

## 3. EVE 格式详解

### 3.1 事件类型 (event_type)

EVE 格式通过 `event_type` 字段区分不同事件：

| event_type | 说明      | Suricata | Zeek |
| :--------- | :-------- | :------: | :--: |
| `conn`     | 连接记录  |    ✅    |  ✅  |
| `http`     | HTTP 请求 |    ✅    |  ✅  |
| `dns`      | DNS 查询  |    ✅    |  ✅  |
| `tls`      | TLS 会话  |    ✅    |  ✅  |
| `ssh`      | SSH 握手  |    ✅    |  ✅  |
| `smtp`     | SMTP 会话 |    ✅    |  ✅  |
| `file`     | 文件传输  |    ✅    |  ✅  |
| `alert`    | 告警      |    ✅    |  -   |
| `netflow`  | NetFlow   |    ✅    |  -   |
| `统计`     | 统计信息  |    ✅    |  -   |

### 3.2 归一化字段

EVE 格式定义了一套**统一字段**，无论来源工具是什么：

```json
{
  "timestamp": "2026-04-15T10:30:00.123456Z",
  "event_type": "conn",

  "src_ip": "192.168.1.100",
  "src_port": 54321,
  "dest_ip": "93.184.216.34",
  "dest_port": 443,
  "proto": "tcp",

  "app_proto": "http",

  "flow_id": 1234567890,

  "zeek": {
    "uid": "ChhnUs4ev9k2",
    "id.orig_h": "192.168.1.100",
    "id.orig_p": 54321,
    "id.resp_h": "93.184.216.34",
    "id.resp_p": 443
  }
}
```

**核心归一化字段**：

| 字段         | 类型    | 说明                 |
| :----------- | :------ | :------------------- |
| `timestamp`  | string  | ISO8601 时间戳       |
| `event_type` | string  | 事件类型             |
| `src_ip`     | string  | 源 IP                |
| `src_port`   | integer | 源端口               |
| `dest_ip`    | string  | 目的 IP              |
| `dest_port`  | integer | 目的端口             |
| `proto`      | string  | 传输层协议 (tcp/udp) |
| `app_proto`  | string  | 应用层协议           |
| `flow_id`    | integer | 流 ID (Suricata)     |
| `in_iface`   | string  | 入接口               |

### 3.3 conn 事件详解

**Zeek EVE conn 事件**：

```json
{
  "timestamp": "2026-04-15T10:30:00.123456Z",
  "event_type": "conn",
  "src_ip": "192.168.1.100",
  "src_port": 54321,
  "dest_ip": "93.184.216.34",
  "dest_port": 443,
  "proto": "tcp",
  "app_proto": "ssl",
  "flow_id": 0,
  "zeek": {
    "uid": "ChhnUs4ev9k2",
    "id.orig_h": "192.168.1.100",
    "id.orig_p": 54321,
    "id.resp_h": "93.184.216.34",
    "id.resp_p": 443,
    "proto": "tcp",
    "service": "ssl",
    "duration": 12.345,
    "orig_bytes": 1234,
    "resp_bytes": 5678,
    "conn_state": "SF",
    "local_orig": true,
    "local_resp": false,
    "missed_bytes": 0,
    "history": "Sf"
  }
}
```

### 3.4 http 事件详解

**Zeek EVE http 事件**：

```json
{
  "timestamp": "2026-04-15T10:30:00.123456Z",
  "event_type": "http",
  "src_ip": "192.168.1.100",
  "src_port": 54321,
  "dest_ip": "93.184.216.34",
  "dest_port": 443,
  "proto": "tcp",
  "app_proto": "http",
  "zeek": {
    "uid": "ChhnUs4ev9k2",
    "method": "GET",
    "host": "example.com",
    "uri": "/api/v1/users",
    "user_agent": "curl/7.68.0",
    "status_code": 200,
    "status_msg": "OK",
    "resp_fuids": ["FkkXa21R123"],
    "resp_mime_types": ["application/json"]
  }
}
```

### 3.5 dns 事件详解

**Zeek EVE dns 事件**：

```json
{
  "timestamp": "2026-04-15T10:30:00.123456Z",
  "event_type": "dns",
  "src_ip": "192.168.1.100",
  "src_port": 54321,
  "dest_ip": "8.8.8.8",
  "dest_port": 53,
  "proto": "udp",
  "app_proto": "dns",
  "zeek": {
    "uid": "XYz123",
    "query": "google.com",
    "qtype": "A",
    "rcode": "NOERROR",
    "answers": ["142.250.80.46"],
    "ttl": [300]
  }
}
```

---

## 4. Zeek 与 Suricata EVE 字段映射

### 4.1 连接日志映射

| Suricata EVE  | Zeek EVE       | 说明           |
| :------------ | :------------- | :------------- |
| `src_ip`      | `src_ip`       | 源 IP          |
| `src_port`    | `src_port`     | 源端口         |
| `dest_ip`     | `dest_ip`      | 目的 IP        |
| `dest_port`   | `dest_port`    | 目的端口       |
| `proto`       | `proto`        | 协议           |
| `app_proto`   | `app_proto`    | 应用层协议     |
| `flow_id`     | -              | Suricata 流 ID |
| -             | `zeek.uid`     | Zeek 连接 UID  |
| `tcp_flags`   | `zeek.history` | TCP 标志/历史  |
| `flowalerted` | -              | 流是否触发告警 |

### 4.2 HTTP 日志映射

| Suricata EVE       | Zeek EVE           | 说明       |
| :----------------- | :----------------- | :--------- |
| `http.method`      | `zeek.method`      | HTTP 方法  |
| `http.url`         | `zeek.uri`         | 请求 URI   |
| `http.hostname`    | `zeek.host`        | Host 头    |
| `http.user_agent`  | `zeek.user_agent`  | User-Agent |
| `http.status_code` | `zeek.status_code` | 状态码     |
| `http.protocol`    | `zeek.version`     | HTTP 版本  |

### 4.3 DNS 日志映射

| Suricata EVE | Zeek EVE       | 说明        |
| :----------- | :------------- | :---------- |
| `dns.type`   | `zeek.qtype`   | 查询类型    |
| `dns.id`     | -              | DNS 事务 ID |
| `dns.rcode`  | `zeek.rcode`   | 响应码      |
| `dns.rrname` | `zeek.query`   | 查询域名    |
| `dns.rdata`  | `zeek.answers` | 响应数据    |

---

## 5. 时间戳同步

### 5.1 时间戳格式

EVE 格式支持多种时间戳格式：

```zeek
# ISO8601 格式（默认，推荐）
redef Log::timestamp_format = "ISO8601";
# 输出: "2026-04-15T10:30:00.123456Z"

# Unix 时间戳（秒）
redef Log::timestamp_format = "UNIX";
# 输出: 1713175800.123456

# Unix 时间戳（毫秒）
redef Log::timestamp_format = "UNIX_MS";
# 输出: 1713175800123
```

### 5.2 时区处理

```zeek
# 使用 UTC 时间
redef Log::use_utc = T;

# 或使用本地时间
redef Log::use_utc = F;
```

### 5.3 Suricata 时间戳配置

```yaml
# /etc/suricata/suricata.yaml

outputs:
  - eve-log:
      enabled: yes
      filename: eve.json
      types:
        - alert
        - http:
            timestamp_format: iso # iso or unix
      identity:
        enabled: no
      community-id: true
```

---

## 6. 多格式输出配置

### 6.1 同时输出 ASCII 和 EVE

```zeek
# /usr/local/zeek/share/zeek/site/multi-format.zeek

@load base/frameworks/logging

# 默认 ASCII 输出（保持兼容性）
redef Log::default_writer = Log::ASCII;
redef Log::default_log_dir = "/var/log/zeek/current";

# EVE-JSON 输出（用于 SIEM）
event zeek_init() {
    # 为每个日志流添加 EVE 过滤器
    for ( id in Log::active_streams() ) {
        local filter_name = fmt("eve-%s", id);

        Log::add_filter(id, [
            $name=filter_name,
            $path=fmt("eve/%s", id),
            $writer=Log::EVE_JSON,
            $include_unset_fields=F
        ]);
    }
}
```

### 6.2 按类型分别输出

```zeek
# /usr/local/zeek/share/zeek/site/type-filtered.zeek

@load base/frameworks/logging

# 仅将高价值日志输出到 EVE
event zeek_init() {
    # HTTP 日志 -> EVE
    Log::add_filter(HTTP::LOG, [
        $name="eve-http",
        $path="eve/http",
        $writer=Log::EVE_JSON
    ]);

    # DNS 日志 -> EVE
    Log::add_filter(DNS::LOG, [
        $name="eve-dns",
        $path="eve/dns",
        $writer=Log::EVE_JSON
    ]);

    # TLS 日志 -> EVE
    Log::add_filter(SSL::LOG, [
        $name="eve-tls",
        $path="eve/tls",
        $writer=Log::EVE_JSON
    ]);
}
```

### 6.3 集群环境 EVE 输出

```zeek
# /usr/local/zeek/share/zeek/site/cluster-eve.zeek

@load base/frameworks/logging
@load base/frameworks/cluster

# Logger 节点专门处理 EVE 输出
event zeek_init() {
    if ( Cluster::node == "logger" ) {
        redef Log::default_writer = Log::EVE_JSON;
        redef Log::default_log_dir = "/var/log/zeek/eve";

        # 启用压缩
        redef Log::log_compression = "gzip";
    }
}
```

---

## 7. EVE 日志处理

### 7.1 日志查看

```bash
# 查看 EVE 日志
cat /var/log/zeek/eve/conn.json | jq .

# 实时跟踪
tail -f /var/log/zeek/eve/conn.json | jq .

# 按 event_type 过滤
jq 'select(.event_type == "http")' /var/log/zeek/eve/conn.json

# 按字段过滤
jq 'select(.src_ip == "192.168.1.100")' /var/log/zeek/eve/conn.json
```

### 7.2 统计分析

```bash
# 统计 event_type 分布
jq -r '.event_type' /var/log/zeek/eve/conn.json | sort | uniq -c

# 统计 HTTP 状态码
jq -r 'select(.event_type == "http") | .zeek.status_code' /var/log/zeek/eve/conn.json | sort | uniq -c

# 统计 Top 10 源 IP
jq -r '.src_ip' /var/log/zeek/eve/conn.json | sort | uniq -c | sort -rn | head
```

### 7.3 与 Suricata EVE 合并

```bash
# 合并两个 EVE 日志（按 timestamp 排序）
cat suricata-eve.json zeek-eve.json | jq -s 'sort_by(.timestamp) | .[]' > merged-eve.json

# 统计合并后的事件类型
jq -r '.event_type' merged-eve.json | sort | uniq -c
```

---

## 8. 常见问题

### 8.1 Zeek UID 处理

Zeek 使用自己的 UID 系统，与 Suricata 的 `flow_id` 不同。合并分析时需要注意：

```json
{
  "zeek": {
    "uid": "ChhnUs4ev9k2" // Zeek UID
  },
  "flow_id": 1234567890 // Suricata flow_id
}
```

### 8.2 Community ID

Community ID 是 Suricata 提出的流指纹，用于跨工具关联：

```yaml
# Suricata 配置
outputs:
  - eve-log:
      community-id: true
```

```zeek
# Zeek 配置 EVE 输出 Community ID
redef Log::community_id = T;
```

```json
{
  "community_id": "1:wAoP8lgR6+iqJ2q3x9lKwA=="
}
```

### 8.3 日志丢失处理

```zeek
# 启用日志缓冲减少丢失
redef Log::write_buffer_size = 16384;
redef Log::log_asynchronous = T;

# 监控日志写入状态
event Log::rotation_whitelist(desc: Log::WriterInfo) {
    print fmt("Rotation: %s, %s", desc$path, desc$open);
}
```

---

## 9. 完整配置示例

```ini
# /usr/local/zeek/etc/zeekctl.cfg
[logging]
logdir = /var/log/zeek/eve
rotation_format = eve
num_rotation_files = 100
use_compression = true
```

```zeek
# /usr/local/zeek/share/zeek/site/eve-complete.zeek

@load base/frameworks/logging
@load base/frameworks/cluster

# =================== EVE 格式配置 ===================
redef Log::default_writer = Log::EVE_JSON;
redef Log::timestamp_format = "ISO8601";
redef Log::use_utc = T;
redef Log::JSON_Separators = {" ", ""};
redef Log::include_unset_fields = F;

# Community ID
redef Log::community_id = T;

# =================== 输出路径 ===================
redef Log::default_log_dir = "/var/log/zeek/eve";

# =================== 日志过滤 ===================
event zeek_init() {
    # 仅输出关键日志到 EVE
    local eve_streams = set(
        HTTP::LOG,
        DNS::LOG,
        SSL::LOG,
        SSH::LOG,
        CONN::LOG
    );

    for ( id in eve_streams ) {
        Log::add_filter(id, [
            $name="eve",
            $path=fmt("eve-%s", id),
            $writer=Log::EVE_JSON
        ]);
    }
}
```

---

## 10. 与 Suricata 联合部署

### 10.1 架构设计

```
┌─────────────────────────────────────────────────────────────┐
│                    联合 NSM 部署                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────┐         ┌─────────┐         ┌─────────┐        │
│  │  Sensor │────────▶│   TAP   │────────▶│  Zeek  │        │
│  │(Suricata)│         └─────────┘         │         │        │
│  └─────────┘                             └────┬────┘        │
│                                               │             │
│                                         EVE-JSON            │
│                                               │             │
│                                               ▼             │
│                                    ┌─────────────────┐      │
│                                    │  SIEM / Log     │      │
│                                    │  Aggregator     │      │
│                                    └─────────────────┘      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 10.2 统一 EVE 处理

```bash
# 使用 jq 处理合并的 EVE 日志
cat /var/log/suricata/eve.json /var/log/zeek/eve/*.json | \
    jq -s 'group_by(.event_type) | map({
        event_type: .[0].event_type,
        count: length,
        first_ts: .[0].timestamp,
        last_ts: .[-1].timestamp
    })'
```

---

## 总结

EVE-JSON 格式为 Zeek 和 Suricata 提供了**统一的日志输出规范**，使得跨工具关联分析和 SIEM 集成更加便捷。关键要点：

1. **启用方式**：`redef Log::default_writer = Log::EVE_JSON`
2. **归一化字段**：统一使用 `src_ip/dest_ip/src_port/dest_port/proto`
3. **工具特定数据**：存放在 `zeek` 子对象中，避免字段冲突
4. **时间戳**：推荐使用 ISO8601 格式，便于跨工具排序
5. **Community ID**：启用后可在不同工具间关联流
