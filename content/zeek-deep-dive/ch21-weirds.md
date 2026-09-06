---
title: "Zeek 深度探索 (二十一)：Weird 日志"
date: 2026-04-15
tags:
  - zeek
  - series
  - weird
  - weird.log
  - anomaly-detection
  - traffic-analysis
description: "深入解析 Zeek Weird 日志——Weird 事件、异常流量检测、weird.log 结构、自定义 weird、异常分析"
---

> [!info] Zeek 2026 深度探索系列 0. [[zeek-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-overview|第一章：Zeek 概述]]
> 2. [[ch2-installation|第二章：安装部署]]
> 3. [[ch3-config|第三章：配置系统]]
> 4. [[ch4-architecture|第四章：Zeek 架构]]
> 5. [[ch5-logging|第五章：日志系统]]
> 6. [[ch6-scriptlang|第六章：ZeekScript 基础]]
> 7. [[ch7-events|第七章：事件]]
> 8. [[ch8-hooks|第八章：Hooks]]
> 9. [[ch9-packages|第九章：Packages]]
> 10. [[ch10-debugging|第十章：调试]]
> 11. [[ch11-http|第十一章：HTTP 分析]]
> 12. [[ch12-dns|第十二章：DNS 分析]]
> 13. [[ch13-tls|第十三章：TLS 分析]]
> 14. [[ch14-smb|第十四章：SMB 分析]]
> 15. [[ch15-ssh|第十五章：SSH 分析]]
> 16. [[ch16-ftp|第十六章：FTP 分析]]
> 17. [[ch17-smtp|第十七章：SMTP 分析]]
> 18. [[ch18-rdp|第十八章：RDP 分析]]
> 19. [[ch19-kafka|第十九章：Kafka 集成]]
> 20. [[ch20-conn|第二十章：连接分析]]
> 21. **第二十一章：Weird 日志**

---

## 1. Weird 概述

"Weird" 是 Zeek 用来标记网络流量中异常或非标准行为的术语。weird.log 记录了 Zeek 检测到的不符合协议规范或异常模式的流量。

### 1.1 什么是 Weird

Weird 事件表示 Zeek 观察到流量中不符合"正常"或"预期"的行为。这可能是：

- 协议违规（如 TCP 选项组合无效）
- 异常模式（如短时间内大量连接）
- 潜在攻击前兆（如 SYN 超时）
- 实现错误（如字段值超出范围）

### 1.2 框架位置

```
$ZEEK_HOME/scripts/base/frameworks/notice/
$ZEEK_HOME/scripts/base/frameworks/analyzer/
├── weird.zeek           # Weird 主脚本
├── weird-add.zeek       # 添加 weird 的脚本
└── ...
```

### 1.3 Weird 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Weird 检测架构                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Packet/Connection Processing                                 │
│       ↓                                                      │
│  Protocol Analyzers                                          │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  weird() 函数调用                                      │  │
│  │  Reporter::weird()                                    │  │
│  │  Analyzer::weird()                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  Weird Filter (throttle/dedup)                              │
│       ↓                                                      │
│  weird.log + Notice (可选)                                  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Weird 日志格式

### 2.1 weird.log 字段详解

```zeek
type Weird::Info = record {
    # 时间戳
    ts: time;                 # 时间戳
    uid: string &optional;    # 连接 UID（如适用）
    id: conn_id &optional;   # 4-tuple（如适用）

    # Weird 标识
    name: string;            # Weird 名称
    weird: string;           # 别名字段

    # 上下文
    c: connection &optional;  # 连接上下文
    addl: string &optional;  # 附加信息
    evidence: bool;          # 是否为证据模式

    # 来源
    source: string;         # 来源 ("analyzer", "reporter", "protocol")

    # 计数
    times: count &optional;   # 发生次数
    other_peers: set[string] &optional;  # 其他报告节点
};
```

### 2.2 weird.log 示例

```
#fields ts uid id.orig_h id.orig_p id.resp_h id.resp_p name addl source
1672531200.123456 Cx1234abcd 192.168.1.100 52341 93.184.216.34 443 unsolicited_web_response " suspicious behavior" analyzer
1672531200.234567 Cx5678efgh 192.168.1.101 44321 10.0.0.1 80 bad_HTTP_request "GET /../../../etc/passwd" protocol
```

### 2.3 主要字段说明

| 字段       | 类型    | 说明                              |
| ---------- | ------- | --------------------------------- |
| `ts`       | time    | 时间戳                            |
| `uid`      | string  | 关联连接 UID                      |
| `id`       | conn_id | 关联连接的 4-tuple                |
| `name`     | string  | Weird 类型名称                    |
| `addl`     | string  | 附加描述信息                      |
| `source`   | string  | 来源 (analyzer/reporter/protocol) |
| `evidence` | bool    | 是否为证据模式                    |

---

## 3. 常见 Weird 类型

### 3.1 TCP 相关 Weird

| Weird 名称                      | 说明             | 可能原因                     |
| ------------------------------- | ---------------- | ---------------------------- |
| `bad_TCP_checksum`              | TCP 校验和错误   | 网络丢包、网卡 offload、攻击 |
| `bad_TCP_options`               | TCP 选项格式错误 | 协议实现错误、攻击           |
| `TCP_challenge_ack`             | Challenge ACK    | 对端不理解某些特性           |
| `TCP_opt_NAK_count`             | NAK 计数异常     | 丢包或攻击                   |
| `unsolicited_TCP_RST`           | 无请求的 RST     | 攻击、端口扫描               |
| `TCP_reuse_of_endpoint`         | 端点重用         | 正常复用或攻击               |
| `bad_TCP_lifetime_of_MSL_timer` | MSL 计时器异常   | 协议错误                     |

### 3.2 HTTP 相关 Weird

| Weird 名称                  | 说明           | 可能原因         |
| --------------------------- | -------------- | ---------------- |
| `bad_HTTP_request`          | 畸形 HTTP 请求 | 攻击、扫描器     |
| `bad_HTTP_reply`            | 畸形 HTTP 响应 | 服务器错误、攻击 |
| `HTTP_masked_proxy_reply`   | 代理响应伪装   | 代理配置错误     |
| `multiple_HTTP_requests`    | 多个 HTTP 请求 | 流水线请求       |
| `overlapping_HTTP_requests` | 重叠 HTTP 请求 | 并发请求错误     |

### 3.3 DNS 相关 Weird

| Weird 名称              | 说明              | 可能原因           |
| ----------------------- | ----------------- | ------------------ |
| `truncated_dns_message` | 截断的 DNS 消息   | 攻击、MTU 问题     |
| `dns_arpa_lookup`       | DNS ARPA 查询     | 扫描行为           |
| `excessive_dns_queries` | 过多 DNS 查询     | DNS 隧道、放大攻击 |
| `long_dns_query`        | 过长的 DNS 查询   | DNS 隧道           |
| `unmatched_dns_reply`   | 不匹配的 DNS 响应 | 缓存污染攻击       |

### 3.4 SSL/TLS 相关 Weird

| Weird 名称                         | 说明               | 可能原因       |
| ---------------------------------- | ------------------ | -------------- |
| `ssl_cert_inconsistent`            | 证书不一致         | MITM 攻击      |
| `ssl_established_but_not_observed` | SSL 建立但未观察到 | 加密分流       |
| `unknown_ssl_version`              | 未知 SSL 版本      | 旧客户端或攻击 |
| `ssl_error_too_many_alerts`        | 过多 SSL 警告      | 攻击或错误实现 |

### 3.5 连接相关 Weird

| Weird 名称                                  | 说明                        | 可能原因       |
| ------------------------------------------- | --------------------------- | -------------- |
| `connection_originator_timed_out`           | 连接 originator 超时        | 扫描、SYN 洪泛 |
| `connection_reused`                         | 连接重用                    | 正常或异常     |
| `inappropriate_protocol`                    | 不适当的协议                | 协议混淆       |
| `payload_ 部分_smaller_than_content_length` | payload 小于 Content-Length | 攻击或错误     |
| `pending_socket_exception`                  | 挂起的 socket 异常          | 实现错误       |

---

## 4. Weird 事件

### 4.1 weird 事件

```zeek
event weird(name: string, addl: string)
```

通用 weird 事件，任何 weird 触发时都会调用。

```zeek
event weird(name: string, addl: string)
    {
    print fmt("[WEIRD] %s: %s", name, addl);
    }
```

### 4.2 weird_with_conn 事件

```zeek
event weird_with_conn(name: string, c: connection, addl: string)
```

关联连接的 weird 事件。

```zeek
event weird_with_conn(name: string, c: connection, addl: string)
    {
    print fmt("[WEIRD] %s: %s -> %s: %s",
              name, c$id$orig_h, c$id$resp_h, addl);

    # 记录到单独的文件
    print fmt("%s | %s | %s", network_time(), name, addl) to stdout;
    }
```

### 4.3 weird_remove_weirds 事件

```zeek
event weird_remove_weirds(name: string, c: connection)
```

当连接关闭，weird 记录被清理时触发。

---

## 5. 触发 Weird

### 5.1 Reporter::weird 函数

```zeek
Reporter::weird(name: string, ...)
Reporter::weird(name: string, c: connection, fmt: string, ...)
```

触发一个 weird 事件。

```zeek
# 简单 weird
Reporter::weird("test_weird", "some additional info");

# 带连接的 weird
Reporter::weird("connection_originator_timed_out", c, "SYN timeout");
```

### 5.2 Reporter::weird 中的格式化

```zeek
event http_request(c: connection, method: string, original_uri: string, version: string)
    {
    # 检测可疑 URI
    if (/|\\|\\.\\./ in original_uri) {
        Reporter::weird("bad_HTTP_request", c,
                       fmt("Suspicious URI: %s", original_uri));
    }
    }
```

### 5.3 协议分析器中的 weird

协议分析器在检测到异常时直接调用 weird：

```zeek
# 在协议分析器中
if (bad_condition) {
    Reporter::weird("protocol_violation", c,
                    fmt("Unexpected value in field: %s", value));
}
```

---

## 6. Weird 配置选项

### 6.1 日志配置

```zeek
# 启用 weird 日志
redef Weird::log_weird = T;

# 日志文件路径
redef Weird::weird_log = "weird";
```

### 6.2 过滤配置

```zeek
# 忽略某些 weird 类型
redef Weird::ignored_weirds = set(
    "test_weird",
    "benign_weird_type"
);

# 过滤来自特定源的 weird
redef Weird::weird_source_filter: table[string] of bool = {
    ["analyzer"] = T,
    ["reporter"] = F,
    ["protocol"] = T,
};
```

### 6.3 节流配置

```zeek
# 每个 weird 类型的最大日志速率
redef Weird::weird_rate_threshold = 50;

# 每个连接的最大 weird 数
redef Weird::weird_per_conn_threshold = 100;

# 全局 weird 速率限制
redef Weird::max_weirds_per_watermark = 10000;
redef Weird::max_weird_interval = 5secs;
```

### 6.4 Notice 联动

```zeek
# 将某些 weird 转为 Notice
redef Weird::weird_types_to_notice: set[string] = {
    "connection_originator_timed_out",
    "bad_HTTP_request",
    "ssl_cert_inconsistent"
};

# 阈值触发 Notice
redef Weird::weird_notice_trigger_count: table[string] of count = {
    ["excessive_dns_queries"] = 10,
    ["TCP_challenge_ack"] = 50,
};
```

---

## 7. Weird 分析实战

### 7.1 统计 Weird 类型

```zeek
global weird_counts: table[string] of count;

event weird_with_conn(name: string, c: connection, addl: string)
    {
    if (name !in weird_counts) {
        weird_counts[name] = 0;
    }
    weird_counts[name] += 1;

    # 周期性报告
    if (weird_counts[name] % 100 == 0) {
        print fmt("[WEIRD STATS] %s: %d occurrences", name, weird_counts[name]);
    }
    }
```

### 7.2 异常 Weird 检测

```zeek
global weird_sources: table[string] of set[string];
global expected_weird_rate = 10;
global baseline_weird_rate = table();

event weird_with_conn(name: string, c: connection, addl: string)
    {
    local src = "unknown";
    if (c?$id) {
        src = fmt("%s", c$id$orig_h);
    }

    if (name !in weird_sources) {
        weird_sources[name] = set();
    }
    add weird_sources[name][src];

    # 检测某类型的异常来源数
    if (|weird_sources[name]| > expected_weird_rate * 10) {
        print fmt("[ALERT] Unexpected spike in %s from %d sources",
                  name, |weird_sources[name]|);

        NOTICE([$note = WEIRD_SPIKE,
                $msg = fmt("Weird %s spike: %d sources", name, |weird_sources[name]|),
                $conn = c]);
    }
    }
```

### 7.3 HTTP 异常检测

```zeek
event weird_with_conn(name: string, c: connection, addl: string)
    {
    # 专门处理 HTTP weird
    if (c?$http && /^bad_HTTP/ in name) {
        print fmt("[HTTP WEIRD] %s from %s: %s (URI: %s)",
                  name, c$id$orig_h, addl, c$http$uri);

        # 路径遍历检测
        if (/\.\.\/|\.\.\\./ in addl) {
            NOTICE([$note = PATH_TRAVERSAL,
                    $msg = fmt("Possible path traversal: %s from %s",
                              addl, c$id$orig_h),
                    $conn = c]);
        }

        # 命令注入检测
        if (/;|\||`|\$\(/ in addl) {
            NOTICE([$note = COMMAND_INJECTION,
                    $msg = fmt("Possible command injection: %s from %s",
                              addl, c$id$orig_h),
                    $conn = c]);
        }
    }
    }
```

### 7.4 DNS 隧道检测

```zeek
event weird_with_conn(name: string, c: connection, addl: string)
    {
    # 检测 DNS 异常
    if (/^excessive_dns_queries$|^long_dns_query$/ in name) {
        print fmt("[DNS WEIRD] %s: %s", name, addl);

        NOTICE([$note = DNS_TUNNEL_SUSPECTED,
                $msg = fmt("Possible DNS tunneling: %s: %s", name, addl),
                $conn = c]);
    }
    }

# 统计单个源的 DNS 查询
global dns_query_count: table[addr] of count;

event dns_query(c: connection, query: string, query_type: count)
    {
    local src = c$id$orig_h;

    if (src !in dns_query_count) {
        dns_query_count[src] = 0;
    }
    dns_query_count[src] += 1;

    if (dns_query_count[src] > 1000) {
        NOTICE([$note = DNS_TUNNEL_SUSPECTED,
                $msg = fmt("High DNS query rate from %s: %d queries",
                          src, dns_query_count[src]),
                $conn = c]);
    }
    }
```

### 7.5 SSL 中间人攻击检测

```zeek
event weird_with_conn(name: string, c: connection, addl: string)
    {
    # 检测 SSL 证书异常
    if (name == "ssl_cert_inconsistent") {
        print fmt("[SSL WEIRD] Certificate inconsistency: %s -> %s: %s",
                  c$id$orig_h, c$id$resp_h, addl);

        NOTICE([$note = SSL_CERT_INCONSISTENT,
                $msg = fmt("SSL certificate inconsistency: %s -> %s",
                          c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }

    if (name == "ssl_established_but_not_observed") {
        print fmt("[SSL WEIRD] SSL established but not observed: %s -> %s",
                  c$id$orig_h, c$id$resp_h);

        NOTICE([$note = SSL_ESTABLISHED_BUT_NOT_OBSERVED,
                $msg = fmt("SSL established but not observed: %s -> %s",
                          c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }
    }
```

---

## 8. Weird 与 Notice 联动

### 8.1 自动转换

```zeek
# 配置哪些 weird 触发 Notice
redef Weird::weird_types_to_notice = {
    "connection_originator_timed_out",
    "bad_TCP_checksum",
    "bad_HTTP_request",
    "ssl_cert_inconsistent"
};
```

### 8.2 阈值触发

```zeek
# 某类型的 weird 达到阈值时触发 Notice
redef Weird::weird_notice_trigger_count = table({
    ["TCP_challenge_ack"] = 100,
    ["excessive_dns_queries"] = 50,
    ["bad_HTTP_request"] = 20
});
```

### 8.3 自定义 Notice 类型

```zeek
# 定义新的 Notice 类型
redef Notice::policy += {
    [$name = "weird_spike",
     $weird = "excessive_dns_queries",
     $threshold = 100,
     $action = Notice::ACTION_LOG,
     $dest = Notice::DEST_EMAIL]
};
```

---

## 9. Weird 日志分析

### 9.1 常用查询

```bash
# 查找高频率 weird
awk '{print $6}' weird.log | sort | uniq -c | sort -rn | head

# 查找特定类型的 weird
grep "bad_HTTP_request" weird.log

# 查找某主机的 weird
grep "192.168.1.100" weird.log

# 统计每个源的 weird 数量
awk -F'\t' 'NR>1 {print $3}' weird.log | sort | uniq -c | sort -rn
```

### 9.2 异常检测脚本

```bash
#!/bin/bash
# 检测 weird 异常

LOG_FILE="weird.log"
THRESHOLD=100

echo "=== Weird Statistics ==="
echo ""

echo "Top 10 Weird Types:"
awk '{print $6}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -10

echo ""
echo "Top 10 Sources:"
awk '{print $3}' "$LOG_FILE" | sort | uniq -c | sort -rn | head -10

echo ""
echo "Weirds per minute (last hour):"
awk -F'\t' 'NR>1 {split($1,t,"."); split(t[1],d,":"); print d[2]}' "$LOG_FILE" | sort | uniq -c

echo ""
echo "Potential Security Issues:"
grep -E "bad_HTTP_request|path_traversal|command_injection|ssl_cert" "$LOG_FILE" | head -20
```

---

## 10. 小结

本章介绍了 Zeek Weird 日志系统：

| 组件                  | 说明                                                    |
| --------------------- | ------------------------------------------------------- |
| **weird.log**         | 记录所有异常流量，包含 weird 类型、连接上下文、附加信息 |
| **Weird::Info**       | Weird 日志的 record 类型                                |
| **Reporter::weird()** | 触发 weird 的主要函数                                   |
| **weird_with_conn**   | 关联连接的 weird 事件                                   |
| **节流/去重**         | 防止 weird 日志过多                                     |

Weird 日志的价值：

- 检测潜在攻击前兆
- 发现配置错误或协议违规
- 识别恶意流量模式
- 与 Notice 联动实现告警

通过分析 weird.log，可以：

- 识别网络中的异常行为
- 检测扫描和探测活动
- 发现数据泄露或隧道
- 识别协议实现错误

下一章我们将讨论文件分析——Zeek 如何提取和分析传输的文件。
