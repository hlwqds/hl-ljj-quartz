---
title: "Zeek 深度探索 (五)：日志系统"
date: 2026-04-15
tags:
  - zeek
  - series
  - logging
  - log-writer
  - ascii
  - json
  - csv
description: "深入解析 Zeek 日志系统——ASCII/JSON/CSV 输出格式、Log Writer 框架、日志轮转机制、核心日志字段、Writer 配置"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. **第五章：日志系统**

---

## 1. 日志系统概述

Zeek 的日志系统是 NSM 框架的**核心输出**，与 Suricata 的 EVE JSON 不同，Zeek 默认输出**多类型结构化日志**，每种日志类型对应一个**日志写入器（Log Writer）**。

### 1.1 日志类型概览

Zeek 默认生成的日志文件：

| 日志文件 | 内容 | 核心字段 |
| :--- | :--- | :--- |
| `conn.log` | 网络连接记录 | uid, id, orig/resp bytes, duration |
| `http.log` | HTTP 请求/响应 | method, uri, status_code, user_agent |
| `dns.log` | DNS 查询/响应 | query, qtype, rcode, answers |
| `ssl.log` | TLS 会话信息 | version, cipher, client_cert, server_cert |
| `ssh.log` | SSH 握手信息 | client, server, version |
| `smtp.log` | SMTP 会话 | from, to, subject, emails |
| `files.log` | 文件传输记录 | fid, mime_type, size, md5/sha1 |
| `weird.log` | 非正常流量 | name, addl |
| `notice.log` | 告警/通知 | note, msg, actions |
| `signatures.log` | 签名匹配 | sig_id, sig_name, action |
| `intel.log` | 威胁情报命中 | indicator, indicator_type, matched |
| `software.log` | 软件指纹 | software, version |

### 1.2 日志框架架构

```
┌──────────────────────────────────────────────────────┐
│              Logging Framework（ZeekScript）           │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐  │
│  │  Log::ID    │→ │  Filter     │→ │  Writer   │  │
│  │  (conn/DNS) │  │  ($path等)   │  │           │  │
│  └──────────────┘  └──────────────┘  └────────────┘  │
├──────────────────────────────────────────────────────┤
│              Writer 层（C++ 实现）                     │
│  ┌────────┐  ┌────────┐  ┌────────┐  ┌──────────┐   │
│  │ ASCII  │  │ JSON   │  │ CSV    │  │  Redis   │   │
│  │Writer  │  │ Writer │  │ Writer │  │  Writer  │   │
│  └────────┘  └────────┘  └────────┘  └──────────┘   │
└──────────────────────────────────────────────────────┘
```

---

## 2. Log Writer 框架

### 2.1 Writer 基类（C++）

```cpp
// src/logging/WriterBackend.h

class WriterBackend {
public:
    // 发送日志头（字段定义）
    virtual bool WriteHeader(const zeek::logging::LogID& id,
                              const std::vector<Field>& fields) = 0;

    // 写入单条记录
    virtual bool Write(int num_fields, const threading::Value* fields) = 0;

    // 写入日志尾
    virtual bool SetBuf(bool buffered) = 0;
    virtual bool Rotate(const char* rotated_path, double open,
                         double close, bool terminating) = 0;
    virtual bool Flush(double network_time) = 0;

    // 初始化/析构
    virtual ~WriterBackend() { }
};
```

### 2.2 可用 Writer

| Writer | 说明 | 源码 | 依赖 |
| :--- | :--- | :--- | :--- |
| **ASCII** | 默认，人类可读 | `src/logging/writers/ASCII.cc` | 无 |
| **JSON** | 结构化 JSON | `src/logging/writers/JSON.cc` | 无 |
| **CSV** | 逗号分隔 | `src/logging/writes/CSV.cc` | 无 |
| **Redis** | Redis Stream | `src/logging/writers/Redis.cc` | hiredis |
| **Null** | 丢弃日志 | `src/logging/writers/Null.cc` | 无 |

---

## 3. ASCII Writer（默认）

### 3.1 输出格式

ASCII Writer 是 Zeek 的**默认日志格式**：

```
#fields ts      uid    id.orig_h   id.orig_p  id.resp_h    id.resp_p  proto  service  duration  orig_bytes  resp_bytes
#types  time    string addr        port        addr         port       enum   string  interval  count       count
1713206400.123  ChhnU4 192.168.1.1  54321      93.184.216.34 443        tcp    ssl     12.345    1234        5678
```

- `#fields`：列头（字段名）
- `#types`：类型注解（每个字段的数据类型）
- `空白行`：数据记录，Tab 分隔

### 3.2 核心字段类型

| 类型前缀 | 说明 | 示例值 |
| :--- | :--- | :--- |
| `time` | Unix 时间戳（秒） | `1713206400.123` |
| `string` | 字符串 | `"hello"` |
| `addr` | IP 地址 | `192.168.1.1` |
| `port` | 端口（带协议） | `443/tcp` |
| `count` | 无符号整数 | `1234` |
| `interval` | 时间间隔（秒） | `12.345` |
| `bool` | 布尔值 | `T` / `F` |
| `enum` | 枚举值 | `tcp` / `udp` |
| `set[string]` | 字符串集合 | `{a,b,c}` |
| `vector[string]` | 字符串向量 | `[a,b,c]` |

### 3.3 conn.log 详解

```bash
#fields                 说明
ts                      时间戳（Unix epoch，秒）
uid                     连接唯一 ID（Zeek 生成）
id.orig_h               源 IP
id.orig_p               源端口
id.resp_h               目的 IP
id.resp_p               目的端口
proto                   协议（tcp/udp/icmp）
service                 应用层服务（http/dns/ssl/...）
duration                连接持续时间（秒）
orig_bytes              源端发送字节数
resp_bytes              响应字节数
conn_state              连接状态（S0/S1/S2/SF/...）
local_orig              源是否为本地网络
local_resp              响应是否为本地网络
missed_bytes            丢失的字节数（重组间隙）
history                 连接历史标志（S/SA/F/R/...）
```

**连接状态码**：

| 状态 | 说明 | 触发条件 |
| :--- | :--- | :--- |
| `S0` | 连接建立中 | 发送 SYN，未收到 SYN-ACK |
| `S1` | 半开连接 | 收到 SYN-SK |
| `S2` | 关闭中（主动） | FIN 发送后收到响应 |
| `S3` | 关闭中（被动） | FIN 收到后发送响应 |
| `SF` | 正常关闭 | 完整握手 + 双方 FIN |
| `REJ` | 连接拒绝 | SYN 被拒绝 |
| `RSTO` | rst 发送方 | 发送 RST |
| `RSTOS0` | RST 后重连 | RST 后重新 SYN |
| `SH` | 半开 | 客户端 SH（仅 SYN） |

---

## 4. JSON Writer

### 4.1 启用 JSON 输出

```bash
# 通过 zeekctl 配置
# 编辑 etc/zeekctl.cfg
[logging]
rotation_format = json
```

```zeek
# 或在 ZeekScript 中配置
redef Log::default_writer = Log::JSON;
```

### 4.2 JSON 格式示例

```json
{
  "ts": 1713206400.123,
  "uid": "ChhnUs4ev9k2",
  "id.orig_h": "192.168.1.100",
  "id.orig_p": 54321,
  "id.resp_h": "93.184.216.34",
  "id.resp_p": 443,
  "proto": "tcp",
  "service": "http",
  "duration": 12.345,
  "orig_bytes": 1234,
  "resp_bytes": 5678,
  "conn_state": "SF",
  "local_orig": true,
  "local_resp": false,
  "missed_bytes": 0,
  "history": "Sf"
}
```

### 4.3 JSON Writer 配置

```zeek
# 自定义 JSON 策略
redef Log::JSON_Separators = {" ", ""};  # 紧凑格式
redef Log::include_unset_fields = F;      # 不包含空字段
redef Log::timestamp_format = "ISO8601";  # ISO8601 时间格式
```

---

## 5. Log Writer 配置（ZeekScript）

### 5.1 Logging Framework API

```zeek
# scripts/base/frameworks/logging/main.zeek

module Log;

export {
    # 全局状态
    global Streams: table[Log::ID] of LogStream;
    global Filters: table[Log::ID] of filter_set;

    # 核心函数
    global create_stream: function(id: Log::ID, path: string): bool;
    global add_filter: function(id: Log::ID, filter: Log::Filter): bool;
    global remove_filter: function(id: Log::ID, name: string): bool;
    global write: function(id: Log::ID, stream: Log::Stream, ...): bool;
    global flush: function(id: Log::ID): bool;

    # 内省
    global active_streams: function(): set[Log::ID];
    global filters: function(id: Log::ID): filter_set;
}
```

### 5.2 Stream 和 Filter

```zeek
# Log::Stream 定义
type Stream: record {
    id: Log::ID;
    path: string;
    enabled: bool;
    postprocessor: function(id: Log::ID, info: Log::WriterInfo): bool;
    filter: filter_set;
};

# Log::Filter 定义
type Filter: record {
    name: string;                  # 过滤器名称
    path: string;                 # 日志路径（可选）
    writer: Log::Writer;           # 写入器类型（ASCII/JSON/CSV/Null）
    writer_opt: table[string, string];  # 写入器选项
    include: Set[string];          # 包含字段
    exclude: Set[string];          # 排除字段
    use_stream_dir: bool;          # 是否在路径前加 stream 名
    log_local_network: bool;       # 是否记录本地网络流量
    interval: interval;            # 轮转间隔（可选）
    num_rotation: count;           # 保留轮转文件数
};
```

### 5.3 自定义日志策略

```zeek
# site/my-logging.zeek

@load base/frameworks/logging

# 定义日志 ID
redef Log::default_filter = Log::Filter(
    $name="mine",
    $writer=Log::JSON,              # 使用 JSON 写入器
    $path="/var/log/zeek/my-log",  # 输出路径
    $include=set("ts", "uid", "id"),
    $exclude=set("some_field")
);

# 自定义过滤：只记录 HTTP POST 请求
event http_request(c: connection, method: string, URI: string, version: string) {
    if (method == "POST") {
        Log::write(HTTP::LOG, $conn=c, $method=method, $URI=URI);
    }
}
```

---

## 6. 日志轮转

### 6.1 轮转机制

Zeek 日志轮转基于**时间间隔**或**文件大小**：

```ini
# etc/zeekctl.cfg

[logging]
# 轮转间隔（分钟）
rotation_interval = 3600   # 1小时

# 轮转后保留文件数
num_rotation_files = 50

# 压缩轮转文件
use_compression = true
```

### 6.2 轮转流程

```
写入日志 → 文件大小超限 OR 时间到
        ↓
关闭当前文件（conn.log.2026-04-15-15-00-00）
        ↓
压缩旧文件（conn.log.2026-04-15-15-00-00.gz）
        ↓
创建新文件（conn.log）
        ↓
删除超期文件（超过 num_rotation_files）
```

### 6.3 手动轮转

```bash
# 手动触发日志轮转
zeekctl
> print

# 强制轮转
zeekctl
> send-command Log::rotate_logs
```

### 6.4 日志文件命名

```
# 轮转前
/var/log/zeek/current/conn.log

# 轮转后
/var/log/zeek/2026-04-15/conn.log.15-00-00
/var/log/zeek/2026-04-15/conn.log.15-00-00.gz
```

---

## 7. 核心日志详解

### 7.1 conn.log（连接记录）

```bash
$ zeek-cut ts uid id.orig_h id.orig_p id.resp_h id.resp_p proto service duration orig_bytes resp_bytes conn_state < conn.log | head -3
1713206400.123  ChhnU4  192.168.1.1   54321    93.184.216.34  443      tcp   ssl     12.345    1234        5678         SF
1713206500.456  ABcdE5  192.168.1.2   12345    8.8.8.8         53       udp   dns     0.023     64          128          S0
```

### 7.2 http.log（HTTP 记录）

```bash
$ zeek-cut ts uid host uri method status_code user_agent resp_fuids < http.log | head -3
1713206400.123  ChhnU4  example.com  /api/v1/users  GET   200   curl/7.68.0   FkkXa21R123
1713206410.234  GHijK6  example.com  /login          POST  302   Mozilla/5.0   GmmYb32S456
```

### 7.3 dns.log（DNS 记录）

```bash
$ zeek-cut ts uid query qtype rcode answers < dns.log | head -3
1713206400.123  XYz123  google.com   A     NOERROR  142.250.80.46
1713206410.234  Abc456  google.com   AAAA  NOERROR  2a00:1450:4009:800::200e
```

### 7.4 weird.log（非正常流量）

```bash
$ zeek-cut ts uid name addl < weird.log | head -3
1713206500.123  ChhnU4  SYN_inside_window   Conn 192.168.1.1 -> 93.184.216.34
1713206600.456  GHijK6  DNS_Truncated_Rsp    Response larger than 512 bytes
```

---

## 8. 日志分析工具

### 8.1 zeek-cut

`zeek-cut` 是 Zeek 自带的日志切割工具，用于快速提取特定字段：

```bash
# 基本用法：提取特定字段
zeek-cut ts id.orig_h id.resp_h < conn.log

# 支持 stdin 管道
cat conn.log | zeek-cut -d '\t' uid orig_bytes resp_bytes

# -d: 指定分隔符（默认 Tab）
# -c: 指定分隔符字符
```

**常用查询**：

```bash
# 查找高流量连接
zeek-cut ts uid orig_bytes resp_bytes < conn.log | sort -k3 -n -r | head

# 统计 HTTP 状态码分布
zeek-cut status_code < http.log | sort | uniq -c | sort -rn

# 查找异常 DNS 查询
zeek-cut query rcode < dns.log | grep -v NOERROR
```

### 8.2 zeek-rotate

```bash
# 手动轮转日志
zeek-rotate -d /var/log/zeek

# -d: 日志目录
```

### 8.3 cat / tail 日志

```bash
# 查看当前日志
cat /var/log/zeek/current/conn.log

# 实时跟踪
tail -f /var/log/zeek/current/conn.log

# tail + zeek-cut 实时分析
tail -f /var/log/zeek/current/http.log | zeek-cut uri status_code
```

---

## 9. 高级配置

### 9.1 禁用特定日志

```zeek
# 禁用 HTTP 日志
@unset HTTP::LOG

# 禁用所有日志
redef Log::default_rotation_interval = 0 sec;

# 仅记录特定日志
redef Log::Streams += {
    [$id=CONN::LOG, $path="conn", $writer=Log::ASCII],
};
```

### 9.2 自定义日志路径

```zeek
# 按日期分目录
redef Log::default_path_func = function(id: Log::ID, path: string): string {
    local now = current_time();
    return fmt("/var/log/zeek/%s/%s", strftime("%Y-%m-%d", now), path);
};
```

### 9.3 多目标输出

```zeek
# 同时输出到文件和 Redis
redef Log::Filters += {
    [$name="redis",
     $path="conn-redis",
     $writer=Log::Redis,
     $writer_opt = table(["host"] = "127.0.0.1", ["port"] = "6379")]
};
```

---

## 10. 性能考虑

### 10.1 日志 I/O 瓶颈

```
日志写入是 Zeek 的主要 I/O 开销：
- conn.log：每个连接至少 1 条（可能 2-3 条）
- http.log：每个 HTTP 请求 1 条
- dns.log：每个 DNS 查询 2 条（query + reply）
- files.log：每个传输文件 1 条
```

**高流量下的日志量估算**：

```
1 Gbps 流量 ≈ 100-500 K connections/min
≈ 100-500 K conn.log/min
≈ 500-2000 K http.log/min（假设每个连接 2-4 个请求）
≈ 500-1000 K dns.log/min
```

### 10.2 优化策略

```zeek
# 1. 禁用不需要的日志
@unscope Log::Streams[DNS::LOG];

# 2. 采样日志（只记录部分流量）
option connection_sampling: set[subnet] = { 192.168.0.0/16 };

# 3. 使用 Null Writer 测试性能
redef Log::default_writer = Log::NULL;

# 4. 调整轮转间隔
redef Log::default_rotation_interval = 1 hr;
```

### 10.3 集群模式日志聚合

在集群模式下，日志由 **Logger 节点** 统一写入：

```
Worker-1 ─┐
Worker-2 ─┤
Worker-3 ─┼──→ Manager ──→ Logger ──→ /var/log/zeek/
Worker-4 ─┤            (Broker)
Worker-5 ─┘
```

Logger 节点收集所有 worker 的日志并统一轮转输出，避免文件冲突。

---

## 11. 本章小结

本章深入解析了 Zeek 的日志系统：

1. **日志类型**：conn/http/dns/ssl/ssh/smtp/files/weird/notice 等 20+ 种日志
2. **Log Writer 框架**：ASCII/JSON/CSV/Redis 等 Writer，C++ 层实现
3. **ASCII Writer 格式**：字段定义、类型注解、Tab 分隔
4. **JSON Writer**：结构化输出，适合 SIEM 集成
5. **Log 配置**：Stream/Filter API、自定义策略
6. **日志轮转**：时间/大小触发、轮转流程
7. **日志分析**：zeek-cut 工具、常用查询示例

**Part I 总结**：以上五章覆盖了 Zeek 的基础入门——概述、安装、配置、架构、日志系统。

**[[2026-04-15-zeek-deep-dive-series-index|返回系列索引]]**
