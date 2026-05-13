---
title: "Zeek 深度探索 (七)：事件"
date: 2026-04-15
tags:
  - zeek
  - series
  - events
  - event-handlers
  - event-queue
  - scripting
description: "深入解析 Zeek 事件驱动模型——事件定义、事件队列调度机制、事件处理程序编写、BRO_EVENT 宏、事件优先级、异步事件处理"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]
> 6. [[2026-04-15-zeek-deep-dive-ch6-scriptlang|第六章：ZeekScript 基础]]
> 7. **第七章：事件**

---

## 1. 事件驱动模型概述

Zeek 的核心执行模型是**事件驱动（Event-driven）**。与传统的顺序执行不同，Zeek 的执行流程由**事件（Event）** 驱动——数据包到达、协议状态变化、计时器触发等都会产生事件，事件处理程序（Event Handler）响应事件并执行业务逻辑。

### 1.1 事件 vs 函数调用

传统函数调用是**同步阻塞**的，而事件处理是**异步解耦**的：

```
传统函数调用：                    事件驱动模型：
┌─────────┐                       ┌─────────┐
│ Caller  │ ─── call() ───→      │  Event  │
└─────────┘        ↓              │ Engine  │
     ↑             ↓              └────┬────┘
     │             ↓                   │
     └── return ───┘                   ├──→ Handler A
                                   ├──→ Handler B
                                   └──→ Handler C
```

| 特性 | 函数调用 | 事件处理 |
| :--- | :--- | :--- |
| 调用方式 | 同步，直接调用 | 异步，通过事件引擎分发 |
| 执行顺序 | 严格顺序 | 不确定（取决于注册顺序） |
| 返回值 | 可直接获取 | 无法直接获取（异步） |
| 耦合度 | 高（直接依赖） | 低（松耦合） |

### 1.2 事件在 Zeek 中的角色

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek 事件驱动流程                        │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  网络数据包                                                   │
│      │                                                       │
│      ↓                                                       │
│  ┌────────────────┐                                         │
│  │   Event Engine  │  (C++ 核心层)                           │
│  │  ─────────────  │                                         │
│  │  协议解析        │                                         │
│  │  状态机追踪      │                                         │
│  │  事件生成        │                                         │
│  └───────┬────────┘                                         │
│          │                                                   │
│          │ 事件分发（dispatch）                               │
│          ↓                                                   │
│  ┌──────────────────────────────────────────┐               │
│  │           事件队列（Event Queue）           │               │
│  │  ┌─────┐ ┌─────┐ ┌─────┐ ┌─────┐       │               │
│  │  │ E1  │ │ E2  │ │ E3  │ │ ... │       │               │
│  │  └─────┘ └─────┘ └─────┘ └─────┘       │               │
│  └──────────────────────────────────────────┘               │
│          │                                                   │
│          │ 按序出队                                           │
│          ↓                                                   │
│  ┌──────────────────────────────────────────┐               │
│  │         Script Interpreter               │               │
│  │  ───────────────────────────────────────│               │
│  │  事件处理程序1 → 事件处理程序2 → ...     │               │
│  └──────────────────────────────────────────┘               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 事件定义

### 2.1 内置事件

Zeek 内置大量事件，由 C++ 核心层在检测到特定条件时触发：

```zeek
# 连接相关事件
event connection_established(c: connection)  # TCP 连接建立
event connection_state_remove(c: connection)  # 连接状态移除
event connection_SYN(c: connection)           # SYN 数据包
event connection_SYNACK(c: connection)       # SYN-ACK 数据包
event connection_reset(c: connection)        # RST 数据包
event connection_finished(c: connection)    # 连接正常关闭

# 数据包事件
event packet(c: connection, p: raw_pkt)     # 原始数据包
event raw_packet(p: raw_pkt)                # 任意原始数据包
event ip_packet(p: ip)                      # IP 数据包

# 协议事件
event http_request(c: connection, method: string, original_URI: string, unescaped_URI: string, version: string)
event http_reply(c: connection, version: string, code: count, reason: string)
event dns_request(c: connection, msg: dns_msg, query: string, qtype: count)
event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count, answer: string)

# 端系统事件
event zeek_init()        # Zeek 启动时
event zeek_done()        # Zeek 关闭时
event zeek_args(args: vector of string)  # 命令行参数
```

### 2.2 事件参数

事件参数通过 **record 类型** 传递，通常包含丰富的信息：

```zeek
# connection_established 事件的 c: connection 参数
# connection 是 Zeek 内置的 record 类型，包含：
type connection: record {
    id: conn_id;           # 连接标识符 (orig_h, orig_p, resp_h, resp_p)
    orig: endpoint;        # 发起端信息
    resp: endpoint;        # 响应端信息
    start_time: time;      # 连接开始时间
    duration: interval;    # 持续时间
    service: set[string];  # 检测到的服务
    ...
};
```

### 2.3 自定义事件（C++ 层）

在 C++ 插件中，可以自定义事件并通过 `mgr.QueueEvent()` 触发：

```cpp
// src/my-plugin/MyAnalyzer.cc

#include "Event.h"
#include "EventHandler.h"
#include "EventManager.h"

// 定义新事件
class MyCustomEvent : public Event {
public:
    MyCustomEvent(const char* msg, uint64_t value)
        : Event("my_custom_event"), message(msg), val(value) {}

    const char* message;
    uint64_t val;

    void Serialize(SerialInfo* info) const override {
        Event::Serialize(info);
        SERIALIZE_STR(message);
        SERIALIZE(val);
    }

    static zeek::EventPtr Deserialize(const SerialInfo* info) {
        std::string msg;
        uint64_t v;
        DESERIALIZE_STR(msg, message);
        DESERIALIZE(v, val);
        return std::make_shared<MyCustomEvent>(msg.c_str(), v);
    }

    void Dispatch(float timeout, bool* timed_out) override {
        // 事件分发逻辑
    }
};

// 触发事件
void MyAnalyzer::DeliverPacket(size_t len, const uint8_t* data) {
    // ...
    if (should_trigger_event) {
        auto event = std::make_shared<MyCustomEvent>("threshold exceeded", 100);
        mgr.QueueEvent(event, 0, nullptr);
    }
}
```

---

## 3. 事件处理程序

### 3.1 事件处理程序语法

事件处理程序（Event Handler）用 `event` 关键字定义：

```zeek
event event_name(param1: type1, param2: type2, ...) {
    # 处理逻辑
}
```

### 3.2 基本示例

```zeek
# Zeek 初始化事件
event zeek_init() {
    print "Zeek is starting...";
    print "Loading scripts...";
}

# Zeek 关闭事件
event zeek_done() {
    print "Zeek is shutting down.";
}

# 连接建立事件
event connection_established(c: connection) {
    print fmt("New connection: %s -> %s",
        c$id$orig_h, c$id$resp_h);
}

# HTTP 请求事件
event http_request(c: connection, method: string, uri: string,
                   version: string) {
    print fmt("HTTP %s %s %s", method, uri, version);
}
```

### 3.3 事件处理程序注册顺序

同一个事件可以注册**多个处理程序**，按**注册顺序**依次执行：

```zeek
# 处理程序 A（先注册）
event http_request(c: connection, method: string, uri: string,
                   version: string) {
    print fmt("[Handler A] %s %s", method, uri);
}

# 处理程序 B（后注册）
event http_request(c: connection, method: string, uri: string,
                   version: string) {
    print fmt("[Handler B] Request to %s", c$host);
}

# 输出顺序：
# [Handler A] GET /api/users HTTP/1.1
# [Handler B] Request to example.com
```

> [!tip] 调试处理程序执行顺序
> 使用 `zeek -b` 加上 `--script-debug` 查看处理程序的注册和执行顺序。

---

## 4. 事件队列与调度

### 4.1 事件队列机制

事件引擎维护一个**优先级队列**，新事件入队后按 FIFO 顺序处理：

```
事件入队（enqueue）                        事件出队（dequeue）
      ↑                                          │
      │                                          ↓
┌─────────────────────────────────────────────────────────┐
│                      事件队列                            │
│  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────┐  ┌─────────┐   │
│  │ E1  │→ │ E2  │→ │ E3  │→ │ E4  │→ │  ...    │   │
│  └─────┘  └─────┘  └─────┘  └─────┘  └─────────┘   │
│   head                                            tail │
└─────────────────────────────────────────────────────────┘
```

### 4.2 事件处理流程

```zeek
# 伪代码：事件处理循环
# while (running) {
#     event = queue.dequeue();    # 阻塞等待
#     handlers = find_handlers(event.type);
#     for (handler in handlers) {
#         handler.execute(event.args);  # 执行处理程序
#     }
# }
```

### 4.3 同步 vs 异步事件

```zeek
# 同步事件（默认）
# 事件处理程序必须执行完毕，才能处理下一个事件

# 异步事件（通过 &concurrency 选项）
event http_request(c: connection, method: string, uri: string) &priority=5 {
    # 这个处理程序可能与其他事件处理程序并发执行
}
```

> [!warning] 竞态条件
> 异步事件处理程序需要考虑**线程安全**。Zeek 的脚本层是**单线程**的，但事件队列本身可能被多 worker 共享。默认情况下，所有事件处理是**串行**的。

---

## 5. 事件优先级

### 5.1 priority 属性

使用 `&priority` 属性控制处理程序的**执行顺序**：

```zeek
# 高优先级（数值越大越先执行）
event http_request(c: connection, method: string, uri: string) &priority=10 {
    print fmt("[HIGH] %s %s", method, uri);  # 先执行
}

# 默认优先级
event http_request(c: connection, method: string, uri: string) {
    print fmt("[DEFAULT] %s %s", method, uri);  # 次执行
}

# 低优先级
event http_request(c: connection, method: string, uri: string) &priority=-5 {
    print fmt("[LOW] %s %s", method, uri);  # 后执行
}
```

> [!info] 默认优先级
> 未指定 `&priority` 时，默认优先级为 **0**。

### 5.2 优先级实战：日志过滤

```zeek
# 高优先级：记录所有请求
event http_request(...) &priority=10 {
    Log::write(HTTP::LOG, [...]);
}

# 中优先级：安全检测
event http_request(...) &priority=5 {
    if (uri contains "' OR 1=1" || uri contains "<script>") {
        NOTICE([$note = HTTP::SQL_INJECTION_ATTEMPT, ...]);
    }
}

# 低优先级：性能监控（最后执行）
event http_request(...) &priority=-10 {
    ++http_request_count;
}
```

---

## 6. 事件属性

### 6.1 &priority

控制处理程序执行顺序（详见第 5 节）。

### 6.2 &group

将处理程序分组，同组处理程序可被统一启用/禁用：

```zeek
event http_request(...) &group="http-logging" {
    Log::write(HTTP::LOG, [...]);
}

event http_request(...) &group="http-security" {
    # 安全检测逻辑
}

# 在其他地方可以针对组操作
event zeek_init() {
    # 禁用 http-logging 组
    # set_record_field() ...
}
```

### 6.3 &new_stream

使日志每次写入都是新文件流：

```zeek
# 用于动态日志路径
event network_hook(...) &new_stream {
    # 每次事件触发都会创建新的日志文件
}
```

### 6.4 &disable_print_hook

禁用该事件的 `print` 钩子输出：

```zeek
event my_verbose_event(...) &disable_print_hook {
    # 该事件不会输出到 stdout
}
```

---

## 7. when 语句（条件事件处理）

### 7.1 when 基本语法

`when` 语句提供**条件等待**机制，只有条件满足时才执行：

```zeek
when (condition) {
    # 条件为真时执行
} else {
    # 可选：条件为假时执行
}
```

### 7.2 when 与事件结合

```zeek
# 等待连接建立
when (c$state == TCP_ESTABLISHED) {
    print "Connection established!";
} else {
    # 超时或状态不满足
    print "Connection not established";
}

# 等待某个值出现在 table 中
global pending_responses: table[string] of string;

event some_event() {
    local query_id = "req-123";

    when (query_id in pending_responses) {
        local response = pending_responses[query_id];
        print fmt("Got response: %s", response);
        delete pending_responses[query_id];
    } else {
        print "Response not yet available";
    }
}
```

### 7.3 when 与定时器

```zeek
# 延迟执行
when (delay 5 secs) {
    print "5 seconds have passed";
}

# 超时控制
when (condition, timeout 10 secs) {
    # 条件满足
} on timeout {
    print "Timeout occurred";
}
```

---

## 8. 定时器事件

### 8.1 周期性定时器

```zeek
# 每 60 秒执行一次
event heartbeat() {
    print fmt("Heartbeat at %s", strftime("%Y-%m-%d %H:%M:%S", current_time()));
    schedule 60 secs { heartbeat() };
}

event zeek_init() {
    schedule 60 secs { heartbeat() };
}
```

### 8.2 一次性定时器

```zeek
event delayed_task() {
    print "This runs once after 10 seconds";
}

event zeek_init() {
    schedule 10 secs { delayed_task() };
}
```

### 8.3 定时器实战：连接超时检测

```zeek
global connection_timestamps: table[addr, addr] of time;

event connection_established(c: connection) {
    local key = (c$id$orig_h, c$id$resp_h);
    connection_timestamps[key] = current_time();

    # 30 秒后检查连接是否还在
    schedule 30 secs { check_connection_timeout(c) };
}

event check_connection_timeout(c: connection) {
    local key = (c$id$orig_h, c$id$resp_h);

    if (key in connection_timestamps) {
        local elapsed = current_time() - connection_timestamps[key];
        if (elapsed > 30 secs) {
            print fmt("Connection %s timeout after %s",
                key, elapsed);
        }
    }
}
```

---

## 9. 事件与日志系统

### 9.1 事件触发的日志写入

Zeek 的日志系统由事件驱动：

```zeek
# HTTP 分析器生成的事件
event http_request(c: connection, method: string, uri: string, ...) {
    # 创建 HTTP 日志记录
    local info: HTTP::Info = [
        $ts = c$start_time,
        $uid = c$uid,
        $id = c$id,
        $method = method,
        $uri = uri,
        ...
    ];

    # 写入日志
    Log::write(HTTP::LOG, info);
}
```

### 9.2 自定义日志流

```zeek
# 定义新的日志 ID
redef enum Log::ID += {
    LOG_MY_APP
};

# 定义日志字段
type MyApp::Info: record {
    ts: time;
    src: addr;
    dst: addr;
    action: string;
    bytes: count;
};

# 启用日志写入器
event zeek_init() {
    Log::create_stream(LOG_MY_APP, [$columns=MyApp::Info, $path="myapp"]);
}

# 写入日志
event my_app_event(src: addr, dst: addr, action: string, bytes: count) {
    Log::write(LOG_MY_APP, [
        $ts = current_time(),
        $src = src,
        $dst = dst,
        $action = action,
        $bytes = bytes
    ]);
}
```

---

## 10. 事件链与状态机

### 10.1 事件链示例：TCP 连接

```
connection_first_packet
        │
        ↓
protocol_confirmation (TCP)
        │
        ↓
connection_established
        │
        ↓
new_connection (注册到连接表)
        │
        ├──→ tcp_segment (多次)
        │         │
        │         ↓
        │    tcp_contents (重组后数据)
        │         │
        │         ↓
        │    http_request / dns_request / etc.
        │
        ↓
connection_state_remove (连接结束)
```

### 10.2 状态追踪

```zeek
# 使用 record 追踪复杂状态
type HTTPTransaction: record {
    ts: time;
    method: string;
    uri: string;
    req_headers: table[string] of string;
    resp_code: count;
    resp_headers: table[string] of string;
};

global http_transactions: table[string] of HTTPTransaction;

event http_request(c: connection, method: string, uri: string, ...) {
    local uid = c$uid;
    http_transactions[uid] = [
        $ts = current_time(),
        $method = method,
        $uri = uri,
        $req_headers = table()
    ];
}

event http_reply(c: connection, code: count, reason: string, ...) {
    local uid = c$uid;
    if (uid in http_transactions) {
        http_transactions[uid]$resp_code = code;
        # 完成事务处理...
    }
}
```

---

## 11. 常见事件使用模式

### 11.1 端点信息访问

```zeek
event connection_established(c: connection) {
    # 发起端
    local orig = c$orig;
    print fmt("Origin: %s:%d", orig$id$resp_h, orig$id$resp_p);
    print fmt("  Bytes: %s", orig$bytes);
    print fmt("  State: %s", orig$state);

    # 响应端
    local resp = c$resp;
    print fmt("Responder: %s:%d", resp$id$resp_h, resp$id$resp_p);
}
```

### 11.2 协议检测确认

```zeek
event protocol_confirmation(c: connection, protocol: string) {
    print fmt("Protocol confirmed: %s for %s", protocol,
        c$id$orig_h);
}

event protocol_violation(c: connection, reason: string) {
    print fmt("Protocol violation: %s - %s",
        c$id$orig_h, reason);
}
```

### 11.3 文件传输追踪

```zeek
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool) {
    print fmt("File %s (%s) on connection %s",
        f$id, f$ mime_type, c$uid);
}

event file_state_remove(f: fa_file) {
    if (f$missing_bytes > 0) {
        print fmt("File %s incomplete: %d bytes missing",
            f$id, f$missing_bytes);
    }
}
```

---

## 12. 本章小结

本章深入讲解了 Zeek 的事件驱动模型：

1. **事件驱动模型**：异步解耦，事件队列按序分发，与传统函数调用有本质区别
2. **内置事件**：连接事件（connection_established 等）、协议事件（http_request 等）、系统事件（zeek_init/zeek_done）
3. **事件处理程序**：`event` 关键字定义，同事件可注册多个处理程序
4. **事件队列**：FIFO 队列，事件按入队顺序处理
5. **事件优先级**：`&priority` 属性控制执行顺序，数值越大越先执行
6. **when 语句**：条件等待，支持超时控制
7. **定时器事件**：`schedule` 函数创建定时器，支持周期性和一次性定时
8. **事件与日志**：日志写入由事件触发，可自定义日志流

**下一章**将介绍 **Hooks**——另一种与事件类似的机制，但提供**短路求值**和**条件触发**的能力。

> [!tip] 延伸阅读
> - [Zeek Events Reference](https://docs.zeek.org/en/stable/scripts/base/frameworks/reporter/)
> - [Event API Documentation](https://docs.zeek.org/en/stable/script-reference/types/event)
