---
title: "Zeek 深度探索 (十)：调试"
date: 2026-04-15
tags:
  - zeek
  - series
  - debugging
  - profiling
  - troubleshooting
description: "深入解析 Zeek 脚本调试技术——zeek -b 调试模式、print/printf 输出、dump_*, script coverage、profiling、常见错误分析"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]
> 6. [[2026-04-15-zeek-deep-dive-ch6-scriptlang|第六章：ZeekScript 基础]]
> 7. [[2026-04-15-zeek-deep-dive-ch7-events|第七章：事件]]
> 8. [[2026-04-15-zeek-deep-dive-ch8-hooks|第八章：Hooks]]
> 9. [[2026-04-15-zeek-deep-dive-ch9-packages|第九章：Packages]]
> 10. **第十章：调试**

---

## 1. 调试模式概述

Zeek 提供多种调试和诊断工具，帮助开发者排查脚本错误和性能问题。

### 1.1 调试工具概览

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek 调试工具集                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  运行时输出                                                  │
│  ├── print              基本输出到 stdout                     │
│  ├── printf             格式化输出                            │
│  └── dump_*             结构化数据导出                        │
│                                                              │
│  调试模式                                                    │
│  ├── zeek -b            调试模式（详细日志）                  │
│  ├── zeek --debug        调试标志                            │
│  └── --script-debug     脚本加载/执行调试                     │
│                                                              │
│  Profiling                                                   │
│  ├── profile.log         脚本执行统计                         │
│  ├── state Profiles      函数调用统计                        │
│  └── script-coverage     代码覆盖分析                        │
│                                                              │
│  诊断工具                                                    │
│  ├── reporter.log        错误/警告日志                        │
│  ├── weird.log          异常流量日志                         │
│  └── Packet Filter      数据包过滤                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. print 与 printf 输出

### 2.1 print 语句

`print` 是最基本的调试输出方式：

```zeek
event zeek_init() {
    # 打印基本类型
    print "Zeek starting...";
    print 42;
    print T;
    print 3.14;

    # 打印复合类型
    local arr = vector(1, 2, 3);
    print arr;

    local tbl = table(["a"] = 1, ["b"] = 2);
    print tbl;

    # 打印 record
    type MyRec: record {
        x: count;
        y: string;
    };
    local rec: MyRec = [$x = 10, $y = "hello"];
    print rec;
}
```

输出：
```
Zeek starting...
42
T
3.140000
[1, 2, 3]
{a: 1, b: 2}
[x: 10, y: hello]
```

### 2.2 printf 格式化

`printf` 提供 C 风格的格式化输出：

```zeek
event connection_established(c: connection) {
    # 基本格式化
    printf("Connection: %s -> %s:%d",
        c$id$orig_h, c$id$resp_h, c$id$resp_p);

    # 数值格式化
    printf("Bytes: %d (orig) vs %d (resp)",
        c$orig$bytes, c$resp$bytes);

    # 地址格式化
    local ip = 192.168.1.1;
    printf("IP: %s (hex: 0x%x)", ip, ip);

    # 多参数
    printf("%s [%s] %s %s - %d bytes",
        c$uid, c$id$orig_h, "->", c$id$resp_h, c$orig$bytes);
}
```

### 2.3 格式说明符

| 说明符 | 含义 | 示例 |
| :--- | :--- | :--- |
| `%s` | 字符串 | `"hello"` |
| `%d` / `%i` | 有符号整数 | `-42` |
| `%u` | 无符号整数 | `42` |
| `%x` | 十六进制 | `0x2A` |
| `%f` | 浮点数 | `3.140000` |
| `%.2f` | 浮点数（2位小数） | `3.14` |
| `%c` | 字符 | `'A'` |
| `%%` | 字面 `%` | `%` |

---

## 3. dump_* 调试函数

### 3.1 dump当前网络连接

```zeek
# 打印当前所有连接表
event zeek_done() {
    print "Dumping all connections...";
    dump_current_connection();
}
```

### 3.2 dump_table / dump_vector

```zeek
event zeek_init() {
    # 调试 table
    global ip_map: table[addr] of string;
    ip_map[192.168.1.1] = "host1";
    ip_map[10.0.0.1] = "server";

    dump_table(ip_map, "IP Map");

    # 调试 vector
    local vec = vector(1, 2, 3, 4, 5);
    dump_vector(vec, "Number Vector");
}
```

### 3.3 dump_event_handlers

```zeek
# 列出所有注册的事件处理程序
event zeek_init() {
    print "Registered event handlers:";
    dump_event_handlers();
}
```

---

## 4. zeek -b 调试模式

### 4.1 基本用法

```bash
# 启动调试模式
zeek -b -i eth0

# 调试模式输出更详细的信息
# - 脚本加载过程
# - 事件处理程序执行
# - 变量状态变化

# 查看详细帮助
zeek -h | grep -i debug
```

### 4.2 --script-debug

```bash
# 显示脚本加载和执行的详细信息
zeek -b --script-debug -i eth0

# 输出示例：
# Loading script /usr/local/zeek/share/zeek/scripts/base/init.zeek
# Executing zeek_init at scripts/base/init.zeek:123
# Loading script scripts/base/frameworks/intel/main.zeek
# Event: connection_established (192.168.1.1:12345 -> 10.0.0.1:80)
# Handler: connection_established at my-script.zeek:45
```

### 4.3 调试输出重定向

```bash
# 将调试输出重定向到文件
zeek -b -i eth0 2>&1 | tee debug.log

# 后台运行并保存输出
nohup zeek -b -i eth0 > zeek-debug.log 2>&1 &
```

---

## 5. 常见错误诊断

### 5.1 类型错误

```zeek
# 错误：类型不匹配
local x: count = "hello";  # Error: cannot convert string to count

# 错误：类型推断失败
local y = 1 + "2";         # Error: no overload for count + string

# 正确做法
local a = 1 + to_count("2");  # 3
local b = cat(1) + "2";       # "12"（字符串连接）
```

### 5.2 未定义变量

```zeek
# 错误：使用未定义变量
print undefined_var;  # Error: unknown identifier

# 正确做法：先定义
global defined_var: count = 0;
print defined_var;
```

### 5.3 record 字段访问

```zeek
type MyRec: record {
    x: count;
    y: string;
};

local r: MyRec;

# 错误：访问不存在字段
print r$z;  # Error: no field z in record

# 错误：访问可选字段前未检查
print r?$z;  # 检查是否存在

# 正确做法
if (r?$z) {
    print r$z;
}
```

### 5.4 table 键不存在

```zeek
global tbl: table[string] of count;

# 错误：访问不存在的键
print tbl["nonexistent"];  # 可能产生运行时错误

# 正确做法：先检查
if ("key" in tbl) {
    print tbl["key"];
}

# 或者使用 default 值
print tbl["key"] ?default 0;
```

---

## 6. Profiling 与统计

### 6.1 启用 profiling

```bash
# 启用脚本 profiling
zeek -b --profile-interval=10 -i eth0

# 生成文件：
# - prof.log    : 处理程序执行时间统计
# - state       : 函数调用统计
```

### 6.2 prof.log 分析

```bash
# 查看 profiling 输出
cat prof.log

# 示例内容：
# <script>                                  #ts    hits  time(s)  avg(ms)
# /usr/local/zeek/scripts/base/init.zeek   0.000      1    0.001    1.000
# connection_established                    0.123      5    0.456    0.091
# http_request                              0.234     10    1.234    0.123
```

### 6.3 state 文件

```bash
# 查看函数调用统计
cat state

# 示例：
# Function call statistics:
# sort() called 1000 times, 0.5s total, 0.0005s avg
# tolower() called 5000 times, 0.8s total, 0.00016s avg
```

### 6.4 内存 profiling

```bash
# 启用内存统计
zeek -b --show-memory -i eth0

# 输出：
# Current memory usage: 1.2 GB
# Peak memory usage: 2.5 GB
# Total events processed: 1000000
```

---

## 7. Script Coverage 分析

### 7.1 启用 coverage

```bash
# 生成代码覆盖报告
zeek -b --script-coverage coverage.out -i eth0

# 运行一段时间后 Ctrl+C 停止
```

### 7.2 分析 coverage 文件

```bash
# 使用 zeek-cut 分析
zeek-cut < coverage.out

# 或者使用 zkg 的 coverage 工具
zkg coverage coverage.out
```

### 7.3 解读 coverage

```
# coverage.out 示例：
# File: /opt/zeek/scripts/my-script.zeek
#   Line 10: 100% (event zeek_init)
#   Line 20: 100% (event connection_established)
#   Line 45:   0% (event never triggered)
#   Line 67:  50% (conditional branch)
```

---

## 8. 日志文件诊断

### 8.1 reporter.log

Reporter 日志记录错误、警告和信息性消息：

```
# reporter.log 示例
1213204567.234567 error: unknown identifier "undefined_var" in my-script.zeek:15
1213204568.345678 warning: division by zero at calc.zeek:67
1213204569.456789 info: script loaded successfully
```

### 8.2 weird.log

Weird 日志记录非正常/意外的流量：

```
# weird.log 字段
# ts - 时间戳
# uid - 连接 UID
# id - 连接标识符
# name - weird 类型
# addl - 附加信息

# 示例
1213204567.234567 ChhnUs4ev9k2 192.168.1.1 443 weird_name "additional info"
```

### 8.3 常用 weird 类型

| 类型 | 含义 |
| :--- | :--- |
| `line_terminated_with_risk` | 可疑行终止 |
| `above_hole_data_without_any_acks` | 可能的空扫描 |
| `connection_originator_SYN_ack` | 异常 SYN/ACK |
| `DNS_Binary_exfiltration` | DNS 二进制隧道 |
| `PASSWORD_GRAB_attempt` | 密码抓取尝试 |

---

## 9. 调试技巧

### 9.1 条件断点（通过 print）

```zeek
event http_request(c: connection, method: string, uri: string, ...) {
    # 条件断点：仅当 uri 包含特定字符串时打印
    if ("admin" in uri || "login" in uri) {
        printf("[DEBUG] Suspicious URI: %s from %s", uri, c$id$orig_h);
    }

    # 特定 IP 断点
    if (c$id$orig_h == 192.168.1.100) {
        printf("[DEBUG] Connection from specific IP");
        print c;
    }
}
```

### 9.2 调用栈追踪

```zeek
# 追踪事件调用链
event http_request(c: connection, method: string, uri: string, ...) {
    printf("[CALL] http_request: %s %s", method, uri);

    # 手动追踪嵌套调用
    if (debug_mode) {
        print "  -> calling helper_function()";
    }
}

function helper_function() {
    if (debug_mode) {
        print "  <- returned from helper_function()";
    }
}
```

### 9.3 变量检查辅助函数

```zeek
# 调试辅助函数
function dump_connection(c: connection) {
    printf("=== Connection %s ===", c$uid);
    printf("  Orig: %s:%d (bytes=%d, pkts=%d)",
        c$id$orig_h, c$id$orig_p, c$orig$bytes, c$orig$pkts);
    printf("  Resp: %s:%d (bytes=%d, pkts=%d)",
        c$id$resp_h, c$id$resp_p, c$resp$bytes, c$resp$pkts);
    printf("  State: %s, Duration: %s",
        c$state, c$duration);
    printf("========================");
}

event connection_established(c: connection) {
    if (debug_mode) {
        dump_connection(c);
    }
}
```

### 9.4 时间测量

```zeek
# 测量代码执行时间
event zeek_init() {
    local start = current_time();

    # 执行耗时操作
    @load scripts/base/policy/protocols/http/detailed

    local elapsed = current_time() - start;
    printf("[TIMING] Script loading took: %.3f seconds", elapsed);
}

# 测量事件处理时间
global http_handler_times: vector of interval;

event http_request(c: connection, method: string, uri: string, ...) {
    local start = current_time();

    # 处理逻辑...

    local elapsed = current_time() - start;
    http_handler_times += elapsed;

    if (|http_handler_times| >= 100) {
        local avg = 0.0;
        for (t in http_handler_times) {
            avg += t;
        }
        avg = avg / |http_handler_times|;
        printf("[TIMING] Avg HTTP handler time: %.3f ms", avg * 1000);
        http_handler_times = vector();
    }
}
```

---

## 10. 常见问题排查

### 10.1 脚本不执行

```bash
# 检查 1：脚本是否被加载
zeek -b -i eth0 --script-debug 2>&1 | grep "my-script"

# 检查 2：@load 路径是否正确
zeek -b -e '@load my-script' -i eth0

# 检查 3：权限问题
ls -la /path/to/my-script.zeek
```

### 10.2 事件未触发

```bash
# 检查 1：协议分析器是否启用
zeek -b -i eth0 --show-plugins | grep HTTP

# 检查 2：事件处理程序是否注册
zeek -b -i eth0 --script-debug 2>&1 | grep "http_request"

# 检查 3：查看 weird.log 是否有协议检测失败
cat weird.log | grep "protocol"
```

### 10.3 性能问题

```bash
# 检查 1：生成 prof.log
zeek -b --profile-interval=30 -i eth0
# 查看 prof.log 中耗时最长的处理程序

# 检查 2：内存使用
zeek -b --show-memory -i eth0

# 检查 3：查看是否有大量 weird
cat weird.log | cut -f6 | sort | uniq -c | sort -rn | head -20
```

### 10.4 连接丢失

```bash
# 检查 1：PF_RING 负载均衡配置
zeek -b -i eth0

# 检查 2：查看是否有丢包报告
cat reporter.log | grep "dropped"

# 检查 3：调整 worker 数量
zeekctl
> deploy
> stop
# 编辑 node.cfg 增加 worker 数量
> deploy
```

---

## 11. 远程调试

### 11.1 使用 zeekctl 调试

```bash
# 查看节点状态
zeekctl status

# 查看单个节点日志
zeekctl log worker-1

# 诊断节点
zeekctl diag worker-1
```

### 11.2 动态修改日志级别

```zeek
# 在运行时启用调试
event zeek_init() {
    # 启用详细日志
    Reporter::info("Debug mode enabled");
}
```

---

## 12. 本章小结

本章介绍了 Zeek 脚本调试和诊断技术：

1. **print / printf**：最基本的调试输出，支持基本类型和复合类型
2. **dump_*** 函数：结构化数据导出（table、vector、connection）
3. **zeek -b 调试模式**：详细的事件和脚本执行日志
4. **--script-debug**：脚本加载和执行过程的完整追踪
5. **常见错误**：类型错误、未定义变量、record 访问、table 键访问
6. **Profiling**：prof.log、state 文件、内存统计
7. **Script Coverage**：代码覆盖分析，识别未执行代码
8. **日志诊断**：reporter.log、weird.log 的使用
9. **调试技巧**：条件断点、时间测量、调用栈追踪
10. **常见问题排查**：脚本不执行、事件未触发、性能问题、连接丢失

**下一章（Part III：协议分析）** 将深入讲解 **HTTP 分析器**——分析器的注册、HTTP::Info record、请求/响应日志字段解析。

> [!tip] 延伸阅读
> - [Zeek Debugging](https://docs.zeek.org/en/stable/media/script-debugging.gif)
> - [Zeek Troubleshooting](https://docs.zeek.org/en/stable/troubleshooting/)
