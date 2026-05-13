---
title: "Zeek 深度探索 Ch42：Zeek 高级脚本编程"
date: 2026-04-15
tags: [zeek, series, scripting, advanced]
description: "Zeek 高级脚本编程：事件、钩子、调试技术与复杂检测脚本"
---

# Zeek 深度探索 Ch42：Zeek 高级脚本编程

## 概述

Zeek的脚本语言是实现复杂检测逻辑的核心。掌握高级事件处理、钩子机制和调试技术是编写有效Zeek脚本的关键。本章深入探讨Zeek脚本编程的高级特性。

## 事件系统深入

### 事件处理机制

Zeek事件驱动架构中，事件是通知发生了什么的基本机制。

```zeek
# 事件定义
event http_message_done(c: connection, version: string, code: count, reason: string) {
    # 检查HTTP响应码
    if (code == 200) {
        Log::write(HTTP::LOG, [
            $ts=current_time,
            $uid=c$uid,
            $id=c$id,
            $code=code
        ]);
    }
}
```

### 事件处理优先级

```zeek
# 高优先级处理程序 - 首先执行
event connection_established(c: connection) &priority=10 {
    print "HIGH: Connection established";
}

# 默认优先级处理程序
event connection_established(c: connection) &priority=0 {
    print "NORMAL: Connection established";
}

# 低优先级处理程序 - 最后执行
event connection_established(c: connection) &priority=-10 {
    print "LOW: Connection established";
}
```

### 事件调度与队列

```zeek
# 延迟事件调度
event http_reply(c: connection, code: count, reason: string) {
    # 调度一个延迟事件
    schedule 5 secs { suspicious_activity(c) };
}

event suspicious_activity(c: connection) {
    # 延迟执行的逻辑
    print "Checking suspicious HTTP activity after 5 seconds";
}
```

## 钩子机制

### 钩子与事件的区别

| 特性 | 事件(Event) | 钩子(Hook) |
|------|-------------|------------|
| 执行顺序 | 按优先级串行 | 串行执行直到被阻止 |
| 返回值 | 无 | 可选布尔值 |
| 使用场景 | 通知/日志 | 访问控制/数据验证 |

### 钩子定义和使用

```zeek
# 定义一个日志钩子
hook HTTP::log_hook(rec: HTTP::Info) {
    # 检查是否应该记录
    if (rec$method == "OPTIONS") {
        # 阻止记录OPTIONS请求
        break;
    }
    
    # 添加额外字段
    rec$custom_tag = "inspected";
}

# 使用钩子
event zeek_init() {
    Log::create_stream(HTTP::LOG, [$columns=HTTP::Info, $path="http"]);
    Log::add_filter(HTTP::LOG, [
        $name="custom",
        $hook=HTTP::log_hook
    ]);
}
```

### 协议钩子

```zeek
# DNS协议钩子 - 用于修改DNS响应
hook DNS::modify_reply(d: dns_msg, reply: dns_answer, query: string) {
    # 检查恶意域名
    if (query == "malicious-domain.com") {
        # 修改响应为空
        reply$answers = vector();
    }
}

# SMTP协议钩子 - 邮件附件检查
hook SMTP::log_hook(rec: SMTP::Info) {
    if (rec?$attachments && |rec$attachments| > 0) {
        for (attachment in rec$attachments) {
            print fmt("SMTP Attachment: %s", attachment);
        }
    }
}
```

## 高级数据类型

### 集合和表

```zeek
# 集合(Set) - 无序唯一元素
global suspicious_ips: set[addr];

event connection_established(c: connection) {
    if (c$id$orig_h in suspicious_ips) {
        print "Suspicious connection detected";
    }
}

# 表(Table) - 键值映射
global connection_tracker: table[addr] of count;

event new_connection(c: connection) {
    if (c$id$orig_h in connection_tracker) {
        connection_tracker[c$id$orig_h] += 1;
    } else {
        connection_tracker[c$id$orig_h] = 1;
    }
}
```

### 记录类型扩展

```zeek
# 定义扩展记录类型
type HTTP::Info: record {
    ts: time;
    uid: string;
    id: conn_id;
    method: string;
    host: string;
    uri: string;
    status_code: count;
    # 添加自定义字段
    custom_tag: string &optional;
    threat_intel: bool &default=F;
};

# 使用记录
event http_request(c: connection, method: string, original_URI: string, version: string) {
    local http_rec: HTTP::Info =$c$http;
    http_rec$custom_tag = "malware-check";
    
    # 检查威胁情报
    if (original_URI contains ".exe") {
        http_rec$threat_intel = T;
    }
}
```

## 调试技术

### 打印调试

```zeek
# 基本打印
print "Connection established";

# 格式化打印
print fmt("HTTP request: %s %s from %s", 
    method, original_URI, c$id$orig_h);

# 条件打印
event connection_state_remove(c: connection) {
    if (c$duration > 10 secs) {
        print fmt("Long connection: %s duration=%s", 
            c$id, c$duration);
    }
}
```

### 断点调试

```zeek
# 使用breakpoint语句（需要gdb或debug模式）
event new_connection(c: connection) {
    # 在此处设置断点
    break;
}
```

### 调试脚本

```bash
# 使用-debug标志运行Zeek
zeek -debug my-script.zeek

# 启用堆栈跟踪
ZEEKPAGER=less zeek -b script.zeek
```

### 性能分析

```zeek
# 使用profile脚本
@load tuning/track-memeory.zeek
@load tuning/load-scaling.zeek

# 查看内存使用
global memory_profile: event();

event memory_profile() {
    local mem = memory_usage();
    print fmt("Memory: %.2f MB", mem$total / 1024.0 / 1024.0);
    schedule 60 secs { memory_profile() };
}

event zeek_init() {
    schedule 60 secs { memory_profile() };
}
```

## 复杂检测脚本示例

### 恶意连接检测

```zeek
# 检测可疑的长时间连接
global long_connections: table[addr] of connection;

event connection_established(c: connection) {
    long_connections[c$id$orig_h] = c;
}

event connection_state_remove(c: connection) {
    if (c$duration > 10 mins) {
        Log::write(ALERT_LOG, [
            $ts=current_time(),
            $src=c$id$orig_h,
            $dst=c$id$resp_h,
            $duration=c$duration,
            $alert="Long suspicious connection"
        ]);
    }
    
    # 清理表
    delete long_connections[c$id$orig_h];
}
```

### DNS隧道检测

```zeek
# DNS隧道检测脚本
module DNS_Tunnel;

export {
    redef enum Log::ID += { LOG };
    
    global last_dns_query: table[string] of count;
    threshold_per_domain: count = 50;
}

event dns_request(c: connection, msg: dns_msg, query: string, qtype: count) {
    # 记录每个域名的查询次数
    if (query in last_dns_query) {
        last_dns_query[query] += 1;
    } else {
        last_dns_query[query] = 1;
    }
    
    # 检测高频查询
    if (last_dns_query[query] > threshold_per_domain) {
        Log::write(LOG, [
            $ts=current_time(),
            $uid=c$uid,
            $id=c$id,
            $query=query,
            $count=last_dns_query[query],
            $reason="High frequency DNS queries"
        ]);
    }
    
    # 检测异常长的子域名
    local parts = split_string(query, /\./);
    if (|parts| > 5) {
        Log::write(LOG, [
            $ts=current_time(),
            $uid=c$uid,
            $id=c$id,
            $query=query,
            $reason="Excessive subdomain depth"
        ]);
    }
}
```

### 文件完整性监控

```zeek
# 检测文件下载并计算哈希
module FileHash;

export {
    global file_hashes: table[string] of string;
}

event file_sniff(f: fa_file, meta: fa_metadata) {
    if (meta?$mime_type && meta$mime_type == "application/x-executable") {
        # 记录可执行文件信息
        print fmt("Executable file detected: %s", f$id);
        print fmt("SHA256: %s", f$seen_bytes);
    }
}

# 记录文件传输大小异常
event file_over_new_connection(f: fa_file, c: connection) {
    if (f$size > 100 MB) {
        Log::write(FILE_LOG, [
            $ts=current_time(),
            $uid=c$uid,
            $id=c$id,
            $filename=f$id,
            $size=f$size,
            $mime_type=f$mime_type,
            $alert="Large file transfer"
        ]);
    }
}
```

## 脚本优化

### 避免全局变量污染

```zeek
# 不推荐：大量全局变量
global counter1: count;
global counter2: count;
global data1: table[addr] of count;

# 推荐：使用模块封装
module MyModule;

export {
    global counter: count = 0;
    global data: table[addr] of count &optional;
}
```

### 事件处理优化

```zeek
# 不推荐：每个事件都处理
event packet(c: connection) {
    process_every_packet(c);
}

# 推荐：批量处理
event packet batch(packets: vector of packet) {
    for (p in packets) {
        process_batch(p);
    }
}
```

### 条件编译

```zeek
# 根据配置启用/禁用功能
@if ZEEK_DEBUG
    print "Debug mode enabled";
@endif

# 条件加载脚本
@if ZEEK_DISABLE_THREAT_INTEL
    # skip threat intel loading
@else
    @load threat-intel
@endif
```

## 测试框架

### 单元测试

```zeek
# 使用Zeek的测试框架
@load testing

test "HTTP detection test" {
    local result = detect_http("GET /index.html HTTP/1.1");
    assert(result == T);
}
```

### 回归测试

```bash
# 运行测试
zeek -b test.zeek

# 使用btest框架
btest -d tests/
```

## 常见错误处理

### 错误处理模式

```zeek
# 使用when语句处理异步错误
when (local result = lookup_addr(c$id$orig_h)) {
    print "Reverse lookup:", result;
} timeout 5 secs {
    print "Lookup timeout";
}
```

### 异常捕获

```zeek
# 检查可选字段
event http_request(c: connection, method: string, 
                   original_URI: string, version: string) {
    # 安全访问可选字段
    if (c$http?$hostname) {
        print c$http$hostname;
    }
}
```

## 总结

掌握Zeek高级脚本编程需要深入理解事件系统、钩子机制和各种调试技术。通过使用模块化设计、适当的优先级设置和有效的调试方法，可以编写出高效、可维护的Zeek检测脚本。不断练习和参考Zeek官方脚本库是提升技能的有效途径。
