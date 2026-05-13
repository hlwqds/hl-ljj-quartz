---
title: "Zeek 深度探索 (三十五)：脚本优化"
date: 2026-04-15
tags:
  - zeek
  - series
  - scripting
  - optimization
  - profiling
  - performance
  - events
description: "深入解析 Zeek 脚本性能优化——事件处理开销分析、profile.log、script profiling、热点函数识别、脚本执行效率提升"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ... 33. [[2026-04-08-zeek-deep-dive-ch33-performance-tuning|第三十三章：性能调优与高级配置]] 34. [[2026-04-15-zeek-deep-dive-ch34-memory|第三十四章：内存调优]] 35. **第三十五章：脚本优化** 36. [[2026-04-15-zeek-deep-dive-ch36-hardware|第三十六章：硬件加速]] 37. [[2026-04-15-zeek-deep-dive-ch37-tuning|第三十七章：Tuning 清单]]

---

## 1. ZeekScript 性能概述

ZeekScript 是 Zeek 的事件驱动脚本语言，虽然设计为人类可读和易用，但在高吞吐量环境下，脚本的执行效率直接影响整体性能。理解事件处理模型和识别热点是优化的关键。

```
┌─────────────────────────────────────────────────────────────┐
│                   ZeekScript 执行模型                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Packet Arrives → Event Engine → Event Queue → Handlers    │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │                   Event Queue                         │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ │   │
│  │  │ Event 1 │ │ Event 2 │ │ Event 3 │ │ Event N │ │   │
│  │  └────▲────┘ └────▲────┘ └────▲────┘ └────▲────┘ │   │
│  │       │           │           │           │         │   │
│  │       └───────────┴───────────┴───────────┘         │   │
│  │                    dispatch order                     │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
│  ┌─────────────────────────────────────────────────────┐   │
│  │               Event Handlers (按优先级)                │   │
│  │  Priority 10: critical (e.g., connection_established)│   │
│  │  Priority 5:  normal (e.g., http_request)           │   │
│  │  Priority 0:  default (most events)                  │   │
│  │  Priority -5: low (e.g., file_over_new_connection)   │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 脚本性能影响因素

| 因素           | 影响程度 | 优化难度 |
| :------------- | :------- | :------- |
| 事件处理频率   | 高       | 中       |
| 正则表达式执行 | 高       | 中       |
| 字符串操作     | 中       | 易       |
| 表/集合查找    | 中       | 易       |
| 定时器数量     | 中       | 易       |
| 日志输出量     | 高       | 易       |

---

## 2. profile.log 详解

`profile.log` 是 Zeek 提供的内置性能分析工具，记录脚本执行的统计数据。

### 2.1 启用 profile.log

```zeek
# local.zeek

# 启用 profiling
@load tuning/profiling

# 配置输出间隔
redef profiling_interval = 60 secs;

# 详细函数级 profiling
redef detailed_profiling = T;
```

```bash
# 或通过命令行启用
zeek -p profiling /path/to/scripts
```

### 2.2 profile.log 字段解析

```
#fields ts      elapsed  events      max_depth  event_queue   script_mem
#types time     count    count       count      count         count
1637845562.123  60.5     1234567     10         500           1048576
```

| 字段          | 类型  | 说明                   |
| :------------ | :---- | :--------------------- |
| `ts`          | time  | 时间戳                 |
| `elapsed`     | count | 自上次输出经过的秒数   |
| `events`      | count | 处理的事件总数         |
| `max_depth`   | count | 事件队列最大深度       |
| `event_queue` | count | 当前事件队列长度       |
| `script_mem`  | count | 脚本层内存使用（字节） |

### 2.3 详细函数 profiling 输出

```
Function profiling:
  count    total    self    per     function
  123456   1.234    0.234   0.000002 zeek_base__dispatch__connection_established
  98765    0.876    0.076   0.000001 zeek_base__log__http
  87654    0.654    0.054   0.000001 zeek_base__misc__load_signatures
```

| 字段    | 说明                               |
| :------ | :--------------------------------- |
| `count` | 函数调用次数                       |
| `total` | 总执行时间（秒）                   |
| `self`  | 自身代码执行时间（不含调用子函数） |
| `per`   | 每次调用平均时间                   |

---

## 3. 事件处理优化

### 3.1 事件处理开销分析

```zeek
# event-timer.zeek - 测量事件处理时间

module EventTimer;

export {
    global event_times: table[string] of vector of interval;
}

event zeek_init() {
    print "Event timing started";
}

event connection_established(c: connection) {
    local start = current_time();
    # ... 处理逻辑 ...
    local elapsed = current_time() - start;

    if ( c$id$orig_h !in event_times ) {
        event_times[c$id$orig_h] = vector();
    }
    add event_times[c$id$orig_h][|event_times[c$id$orig_h]|] = elapsed;
}

event zeek_done() {
    # 输出统计
    for ( h in event_times ) {
        local times = event_times[h];
        local total: interval = 0secs;
        for ( t in times ) {
            total += t;
        }
        local avg = total / |times|;
        print fmt("Host %s: %d events, avg %.6f sec",
            h, |times|, avg);
    }
}
```

### 3.2 事件处理优化原则

```zeek
# 优化原则 1：减少不必要的事件处理

# 差：为每个包触发事件
event packet_in(c: connection, p: pkt_hdr) {
    if ( p$tcp$flags & TCP_SYN ) {
        event tcp_syn(c, p);
    }
}

# 好：直接使用内置事件
event new_connection(c: connection) {
    # Zeek 已经处理了 SYN，直接在正确事件处理
}
```

```zeek
# 优化原则 2：延迟处理

# 差：实时处理每个 HTTP 请求头
event http_request(c: connection, method: string, original_uri: string) {
    local uri = sanitize_uri(original_uri);  # 每次都处理
    if ( /suspicious/ in uri ) {
        NOTICE::make_email_alert(...);
    }
}

# 好：批量检查
module SuspiciousURIChecker;

global pending_uris: set[string];

event http_request(c: connection, method: string, original_uri: string) {
    add pending_uris[original_uri];
}

event http_message_done(c: connection, is_orig: bool, stat: http_message_stat) {
    # 批处理
    for ( uri in pending_uris ) {
        if ( /suspicious/ in uri ) {
            # 处理
        }
    }
    clear pending_uris;
}
```

### 3.3 事件队列管理

```zeek
# 控制事件队列大小
redef event_queue_size = 50000;  # 默认 1000

# 丢弃低优先级事件防止队列积压
redef event_dropped_threshold = 0.8;  # 队列 80% 时开始丢弃

# 事件优先级
# 数值越大优先级越高
event connection_established(c: connection) &priority=10 {
    # 高优先级处理
}
```

---

## 4. 正则表达式优化

### 4.1 正则表达式性能影响

正则表达式是 Zeek 脚本中最常见的性能瓶颈之一。每次包处理时执行的正则表达式会显著影响吞吐量。

```
┌─────────────────────────────────────────────────────────────┐
│                 正则表达式优化策略                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 编译优化                                                │
│     - 预编译正则 /(?i)pattern/ 或 /pattern/i                 │
│     - 避免每次使用时编译                                      │
│                                                              │
│  2. 匹配优化                                                │
│     - 使用锚点 ^ $ 减少回溯                                   │
│     - 避免贪婪匹配 .* 改为 [^ ]*                             │
│     - 使用字符类 [a-z] 而非 a|z                              │
│                                                              │
│  3. 缓存优化                                                │
│     - 连接状态缓存匹配结果                                     │
│     - 避免重复正则匹配                                        │
│                                                              │
│  4. 引擎选择                                                │
│     - PCRE2 比 PCRE 性能更好                                  │
│     - re2（确定性正则）性能更稳定                              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 正则表达式缓存

```zeek
# 差：每次都执行正则
event http_request(c: connection, method: string, uri: string) {
    if ( /\/admin\/|\/wp-login|\/phpmyadmin/ in uri ) {
        NOTICE::weird("Admin access", c);
    }
}

# 好：预编译并缓存
module RegexCache;

export {
    global suspicious_uri_pattern: pattern = /\/admin\/|\/wp-login|\/phpmyadmin/;
    global suspicious_uri_cache: table[count] of bool;
}

event http_request(c: connection, method: string, uri: string) {
    # 在连接状态中缓存结果
    if ( !c?$uri_checked ) {
        c$uri_checked = T;
        c$uri_suspicious = suspicious_uri_pattern in uri;
    }

    if ( c$uri_suspicious ) {
        NOTICE::weird("Admin access", c);
    }
}
```

### 4.3 re2 正则表达式引擎

```zeek
# 使用 re2 引擎（确定性有限自动机，更快更安全）
# 注意：re2 不支持所有 PCRE 特性

redef pattern_引擎 = RE2;  # 需要 Zeek 6.0+

# re2 支持的模式
global safe_patterns: table[string] of pattern = {
    ["email"] = /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,
    ["ipv4"] = /\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}/,
    ["url_path"] = /\/[a-zA-Z0-9\-._~:\/?#\[\]@!$&'()*+,;=%]*/,
};
```

---

## 5. 字符串操作优化

### 5.1 字符串拼接

```zeek
# 差：多次字符串拼接
event http_request(c: connection, method: string, uri: string) {
    local log_msg = "HTTP " + method + " " + uri + " from " + c$id$orig_h;
    print log_msg;
}

# 好：使用 fmt 或 单次拼接
event http_request(c: connection, method: string, uri: string) {
    local log_msg = fmt("%s %s from %s", method, uri, c$id$orig_h);
    print log_msg;
}

# 好：使用 cat
event http_request(c: connection, method: string, uri: string) {
    local log_msg = cat("HTTP ", method, " ", uri, " from ", c$id$orig_h);
    print log_msg;
}
```

### 5.2 字符串查找

```zeek
# 差：多次子串查找
event http_request(c: connection, method: string, uri: string) {
    if ( "admin" in uri && "login" in uri ) {
        # 两次查找
    }
}

# 好：单次正则匹配
event http_request(c: connection, method: string, uri: string) {
    if ( /admin.*login|login.*admin/ in uri ) {
        # 一次正则匹配
    }
}
```

### 5.3 字符串去重

```zeek
# 使用 set 进行字符串去重
global seen_strings: set[string];

event new_connection(c: connection) {
    if ( c$http?$host ) {
        local host = c$http$host;

        # 检测新 host
        if ( host !in seen_strings ) {
            add seen_strings[host];
            # 处理新 host
            print fmt("New host observed: %s", host);
        }
    }
}
```

---

## 6. 表和集合操作优化

### 6.1 表查找优化

```zeek
# 差：多次表查找
event new_connection(c: connection) {
    if ( c$id$orig_h in known_hosts ) {
        if ( known_hosts[c$id$orig_h]$first_seen > 0 ) {
            # ...
        }
    }
}

# 好：单次查找
event new_connection(c: connection) {
    if ( c$id$orig_h in known_hosts ) {
        local host_info = known_hosts[c$id$orig_h];
        if ( host_info$first_seen > 0 ) {
            # ...
        }
    }
}
```

### 6.2 过期数据清理

```zeek
# 定期清理过期数据
module TableCleanup;

export {
    global cleanup_interval = 5mins;
    global entry_ttl = 1hr;
}

event zeek_init() {
    schedule cleanup_interval { cleanup_timer() };
}

event cleanup_timer() {
    local now = network_time();

    # 清理 known_hosts
    for ( h in known_hosts ) {
        if ( now - known_hosts[h]$last_seen > entry_ttl ) {
            delete known_hosts[h];
        }
    }

    # 继续调度
    schedule cleanup_interval { cleanup_timer() };
}
```

### 6.3 使用 bloom filter 加速查找

```zeek
# 对于大型 set，使用 bloom filter 减少内存
# 注意：bloom filter 有假阳性

module BloomFilter;

export {
    global known_evil_hosts: bloomfilter_t[count];
}

function init_bloom() {
    known_evil_hosts = bloomfilter_basic_init(0.001, 10000);
}

event zeek_init() {
    init_bloom();
}

function is_likely_evil(host: string): bool {
    return bloomfilter_contains(known_evil_hosts, host);
}

event new_connection(c: connection) {
    if ( is_likely_evil(c$id$orig_h) ) {
        # 可能的恶意主机，需要进一步检查
        if ( c$id$orig_h in known_evil_hosts_exact ) {
            # 确认是恶意
        }
    }
}
```

---

## 7. Script Profiling 实战

### 7.1 使用 zeek -b 调试模式

```bash
# 启用内置 profiling
zeek -b profile scripts/

# 输出到 stderr
zeek -b -v scripts/

# 输出到文件
zeek -b -B profiling_output=/var/log/zeek/profile.log scripts/
```

### 7.2 使用 gperftools CPU Profiling

```bash
# 启用 CPU profiling
env CPUPROFILE=/var/log/zeek/cpu.prof zeek scripts/

# 分析 CPU profile
google-pprof --text zeek /var/log/zeek/cpu.prof

# 输出火焰图
google-pprof --raw zeek /var/log/zeek/cpu.prof > profile.data
# 使用 FlameGraph 工具生成 SVG
```

### 7.3 识别热点函数

```bash
# perf 采样分析
perf record -F 99 -g -p $(pidof zeek) -- sleep 60
perf report -g --stdio

# 查看热点汇编
perf annotate --stdio
```

### 7.4 脚本级热点识别

```zeek
# hotspot-detector.zeek

module HotspotDetector;

export {
    global hot_functions: table[string] of count;
    global threshold_ms = 10.0;  # 超过 10ms 的调用视为热点
}

event zeek_script_function_call(func_name: string, start: time) {
    hot_functions[func_name] += 1;
}

# 输出热点报告
event zeek_done() {
    print "\n=== Hotspot Report ===";
    for ( func in hot_functions ) {
        local count = hot_functions[func];
        print fmt("%s: called %d times", func, count);
    }

    # 排序输出
    print "\n=== Top 10 Hotspots ===";
    local sorted = topk_create(10);
    for ( func in hot_functions ) {
        topk_increment(sorted, func, hot_functions[func]);
    }
    for ( i = 0; i < 10; i++ ) {
        local entry = topk_next(sorted);
        if ( entry$value != "" ) {
            print fmt("%d. %s: %d calls",
                i+1, entry$value, entry$count);
        }
    }
}
```

---

## 8. 常见脚本性能问题

### 8.1 问题诊断表

| 问题         | 症状                 | 解决方案                      |
| :----------- | :------------------- | :---------------------------- |
| 事件队列积压 | `max_depth` 持续增长 | 优化事件处理函数、增加 worker |
| 正则回溯     | CPU 100%             | 简化正则、使用 re2            |
| 内存泄漏     | RSS 持续增长         | 检查全局表、定期清理          |
| 定时器过多   | 事件处理延迟         | 合并定时器、使用批量处理      |
| 日志过多     | I/O 瓶颈             | 调整日志级别、使用日志过滤    |

### 8.2 性能优化检查清单

```zeek
# performance-checklist.zeek

# 1. 检查事件队列深度
event packet_in(c: connection, p: pkt_hdr) {
    local q_len = event_queue_size();
    if ( q_len > 5000 ) {
        Reporter::warning(fmt("Event queue backlog: %d", q_len));
    }
}

# 2. 检查处理延迟
global last_check = 0.0;
global processing_rate = 0.0;

event every_1_sec() {
    if ( last_check > 0.0 ) {
        local elapsed = network_time() - last_check;
        local events = event_queue_size();
        processing_rate = double(events) / elapsed;

        if ( processing_rate > 100000 ) {
            Reporter::warning("High event processing rate");
        }
    }
    last_check = network_time();
}

# 3. 定期输出统计
event zeek_init() {
    schedule 5mins { print_stats() };
}

event print_stats() {
    print fmt("Time: %s", strftime("%Y-%m-%d %H:%M:%S", network_time()));
    print fmt("Memory: %.2f MB", double(current_memory()) / 1MB);
    print fmt("Events processed: %d", event_sequence_number());
    print "";
    schedule 5mins { print_stats() };
}
```

---

## 9. 脚本优化实战案例

### 9.1 HTTP 日志优化

```zeek
# 原始脚本：每个请求都处理
event http_request(c: connection, method: string, uri: string,
                  version: string, request_line: string) {
    Log::write(HTTP::LOG, [
        $ts=network_time(),
        $uid=c$uid,
        $id=c$id,
        $method=method,
        $uri=uri,
        $version=version
    ]);
}

# 优化版本：批量处理
module OptimizedHTTP;

const flush_interval = 5secs;
global pending_logs: vector of HTTP::Info;
global last_flush = 0.0;

event http_request(c: connection, method: string, uri: string,
                  version: string, request_line: string) {
    add pending_logs[
        pending_logs|] = [
            $ts=network_time(),
            $uid=c$uid,
            $id=c$id,
            $method=method,
            $uri=uri,
            $version=version
        ];
}

event flush_timer() {
    if ( |pending_logs| > 0 ) {
        for ( log_entry in pending_logs ) {
            Log::write(HTTP::LOG, log_entry);
        }
        pending_logs = vector();
    }
    schedule flush_interval { flush_timer() };
}

event zeek_init() {
    schedule flush_interval { flush_timer() };
}
```

### 9.2 DNS 日志优化

```zeek
# 原始：每个 DNS 响应都处理
event dns_request(c: connection, msg: dns_msg, query: string) {
    Log::write(DNS::LOG, [
        $ts=network_time(),
        $uid=c$uid,
        $id=c$id,
        $query=query
    ]);
}

# 优化：去重 + 缓存
module OptimizedDNS;

global unique_queries: set[string];
global query_cache: table[string] of DNS::Info;

event dns_request(c: connection, msg: dns_msg, query: string) {
    if ( query !in unique_queries ) {
        add unique_queries[query];
        Log::write(DNS::LOG, [
            $ts=network_time(),
            $uid=c$uid,
            $id=c$id,
            $query=query
        ]);
    }
}
```
