---
title: "Zeek 深度探索 (八)：Hooks"
date: 2026-04-15
tags:
  - zeek
  - series
  - hooks
  - hook-handlers
  - flow-control
description: "深入解析 Zeek Hook 机制——Hook 与事件的区别、hook 处理程序编写、&priority 短路求值、hook 调用、内置 hook 示例"
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
> 8. **第八章：Hooks**

---

## 1. Hook 机制概述

**Hook** 是 Zeek 提供的另一种**条件触发机制**，与事件（Event）类似但有本质区别。Hook 最大的特点是**短路求值（Short-circuit Evaluation）**——处理程序可以**停止后续处理**；而事件是**广播式**的，所有处理程序都会被执行。

### 1.1 Hook vs Event

```
┌─────────────────────────────────────────────────────────────┐
│                     Event（广播式）                           │
├─────────────────────────────────────────────────────────────┤
│  Event Engine                                                │
│      │                                                       │
│      ├──→ Handler A → Handler B → Handler C → (全部执行)     │
│                                                              │
│  特点：                                                      │
│  • 所有注册的处理程序都会被调用                               │
│  • 处理程序之间无返回值传递                                   │
│  • 无法中断后续处理                                          │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     Hook（短路式）                           │
├─────────────────────────────────────────────────────────────┤
│  Hook Caller                                                │
│      │                                                       │
│      ├──→ Handler A → Handler B [stop] → (提前结束)         │
│      │                                     ↑                │
│      └── (如果有 stop，后续 Handler C 不执行)                │
│                                                              │
│  特点：                                                      │
│  • 处理程序可以返回布尔值                                    │
│  • 返回 F 或调用 stop 可中断后续处理                         │
│  • 支持条件触发                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 核心差异

| 特性         | Event                    | Hook                       |
| :----------- | :----------------------- | :------------------------- |
| **执行模型** | 广播（所有处理程序执行） | 短路（可中断）             |
| **返回值**   | 无                       | `bool`（可选）             |
| **中断能力** | 无                       | `break`/`return F`         |
| **调用方式** | 自动（由事件引擎）       | 显式调用                   |
| **使用场景** | 通用事件处理             | 条件检查、访问控制、预处理 |

---

## 2. Hook 类型定义

### 2.1 Hook 类型声明

```zeek
# 定义一个 hook 类型
type MyHook: hook(param1: type1, param2: type2, ...);
```

### 2.2 内置 Hook 类型示例

Zeek 内置了许多 hook 类型，定义在 `scripts/base/init.zeek` 中：

```zeek
# 连接删除前的 hook（用于清理资源）
type ConnDeletionHook: hook(id: conn_id);

# 协议分析器确认 hook
type ProtocolConfirmationHook: hook(c: connection, protocol: string);

# 审计日志 hook
type AuditHook: hook(id: Log::ID, path: string, filter: Log::Filter);

# Intel 发现 hook（用于扩展情报匹配行为）
type Intel::MatchHook: hook(data: Intel::Info, b: bool);
```

---

## 3. Hook 处理程序

### 3.1 定义 Hook 处理程序

使用 `hook` 关键字定义处理程序：

```zeek
hook MyHook(param1: type1, param2: type2) {
    # 处理逻辑
    # 可以 return F; 来停止后续处理
}
```

### 3.2 基本示例

```zeek
# 定义 hook 类型
type LogFilterHook: hook(msg: string, level: count);

# 定义处理程序 A（高优先级）
hook LogFilterHook(msg: string, level: count) &priority=10 {
    if (level >= 3) {
        print fmt("[HIGH] %s", msg);
    }
    # 不返回 F，继续执行后续处理程序
}

# 定义处理程序 B（默认优先级）
hook LogFilterHook(msg: string, level: count) {
    if (level >= 2) {
        print fmt("[MEDIUM] %s", msg);
    }
}

# 定义处理程序 C（低优先级，会中断）
hook LogFilterHook(msg: string, level: count) &priority=-5 {
    if (level == 1) {
        print fmt("[LOW] %s", msg);
        break;  # 停止后续处理
    }
}

# 定义处理程序 D（最后执行，不会执行到）
hook LogFilterHook(msg: string, level: count) &priority=-10 {
    print fmt("[LAST] %s", msg);  # 永远不会执行
}
```

### 3.3 Hook 处理程序返回值

```zeek
# 返回值 hook
hook Intel::MatchHook(data: Intel::Info, found: bool): bool {
    if (data$indicator == "malicious-domain.xyz") {
        print fmt("Blocking malicious domain: %s", data$indicator);
        return F;  # 返回 F，阻止后续处理
    }
    return T;  # 返回 T，继续执行
}

# 调用者检查返回值
function call_intel_hook(data: Intel::Info): bool {
    local result: bool = T;
    if (hook Intel::MatchHook(data, result)) {
        # hook 执行完成
        return result;
    }
    return F;
}
```

---

## 4. Hook 调用

### 4.1 显式调用 Hook

使用 `hook` 操作符显式调用 hook：

```zeek
# 调用 hook
if (hook MyHook(arg1, arg2)) {
    print "Hook returned T";
} else {
    print "Hook returned F";
}
```

### 4.2 Hook 调用示例

```zeek
# 定义一个连接验证 hook
type ConnectionValidationHook: hook(c: connection);

# 处理程序：检查是否为私有 IP
hook ConnectionValidationHook(c: connection) &priority=10 {
    local orig_ip = c$id$orig_h;
    if (is_private_ip(orig_ip)) {
        print "Private IP detected, allowing";
    } else {
        # 非私有 IP，阻止后续处理
        return F;
    }
}

# 处理程序：检查是否为黑名单 IP
hook ConnectionValidationHook(c: connection) &priority=5 {
    if (c$id$orig_h in blacklist_ips) {
        print "Blacklisted IP blocked";
        return F;
    }
    return T;
}

# 调用 hook
event connection_established(c: connection) {
    if (hook ConnectionValidationHook(c)) {
        print "Connection passed validation";
        # 正常处理连接
    } else {
        print "Connection blocked by hook";
        # 阻止或记录连接
    }
}
```

---

## 5. break 语句

### 5.1 break 的作用

`break` 语句用于**立即停止** hook 的后续处理程序执行：

```zeek
hook MyHook(msg: string) &priority=10 {
    print "[1] Processing";
    # 继续执行后续处理程序
}

hook MyHook(msg: string) &priority=5 {
    print "[2] Processing";
    break;  # 停止后续处理
}

hook MyHook(msg: string) &priority=0 {
    print "[3] This will NOT execute";
}
```

### 5.2 break vs return F

```zeek
# return F：返回 False，但可能继续执行其他处理程序
hook MyHook(...) &priority=10 {
    return F;  # 返回 False，但处理程序继续执行
}

# break：立即停止整个 hook 调用链
hook MyHook(...) &priority=10 {
    break;  # 立即停止，后续处理程序不执行
}
```

> [!warning] 行为差异
>
> - `return F`：当前处理程序返回 False，hook 调用返回 False，但**后续处理程序仍会执行**
> - `break`：立即停止整个 hook 链，**后续处理程序不执行**

---

## 6. 内置 Hooks

### 6.1 zeek_done Hook

Zeek 关闭时调用的 hook，可以有多个处理程序：

```zeek
hook zeek_done() &priority=10 {
    print "Cleanup step 1";
}

hook zeek_done() &priority=5 {
    print "Cleanup step 2";
    break;  # 阻止后续处理（但 zeek_done 仍会执行）
}

hook zeek_done() &priority=0 {
    print "This won't print";
}
```

### 6.2 Intel::MatchHook

威胁情报匹配时的 hook：

```zeek
# 自定义 Intel 匹配处理
hook Intel::MatchHook(data: Intel::Info, found: bool) &priority=10 {
    if (data$indicator_type == Intel::ADDR) {
        print fmt("Found malicious IP: %s", data$indicator);
    }
}

hook Intel::MatchHook(data: Intel::Info, found: bool) &priority=5 {
    if (data$seen$orig_h == 192.168.1.100) {
        # 特殊处理内部受感染主机
        NOTICE([$note = Intel:: MATCH_INDICATOR, ...]);
    }
}
```

### 6.3 Log::rotation_hook

日志轮转时的 hook：

```zeek
hook Log::rotation_hook(path: string, open_time: time) &priority=10 {
    print fmt("Rotating log: %s (opened at %s)", path, open_time);
}

hook Log::rotation_hook(path: string, open_time: time) &priority=5 {
    # 执行自定义上传逻辑
    # upload_to_s3(path);
}
```

---

## 7. Hook 与事件的组合使用

### 7.1 典型模式：Hook 做预处理，Event 做后处理

```zeek
# Hook：验证/过滤
hook ConnectionValidationHook(c: connection): bool {
    # 检查连接是否应该被处理
    if (should_drop_connection(c)) {
        return F;  # 阻止处理
    }
    return T;  # 允许继续
}

# Event：记录/分析
event connection_established(c: connection) {
    # 只有 hook 通过后才执行
    print fmt("Connection established: %s", c$id$orig_h);
}

# 组合使用
event connection_established(c: connection) {
    if (!hook ConnectionValidationHook(c)) {
        return;  # Hook 失败，不处理
    }

    # 正常处理逻辑...
}
```

### 7.2 条件日志示例

```zeek
# 定义日志过滤 hook
type HTTPRequestLogHook: hook(c: connection, uri: string, status: count);

# 允许日志的 hook
hook HTTPRequestLogHook(c: connection, uri: string, status: count) &priority=10 {
    # 禁止记录包含敏感信息的 URI
    if ("password" in uri || "token=" in uri) {
        return F;  # 不记录
    }
    return T;
}

# 速率限制 hook
hook HTTPRequestLogHook(c: connection, uri: string, status: count) &priority=5 {
    # 检查该 IP 的请求频率
    local ip = c$id$orig_h;
    if (ip_rate_exceeded(ip)) {
        return F;  # 超速，不记录
    }
    return T;
}

# 使用 hook 控制是否记录
event http_request(c: connection, method: string, uri: string, ...) {
    if (hook HTTPRequestLogHook(c, uri, 0)) {
        Log::write(HTTP::LOG, [...]);
    }
}
```

---

## 8. Hook 实战：访问控制

### 8.1 连接过滤

```zeek
# 定义连接过滤 hook
type ConnectionFilterHook: hook(c: connection, action: string);

# 黑名单检查
hook ConnectionFilterHook(c: connection, action: string) &priority=10 {
    if (c$id$orig_h in blacklist) {
        action = "block";
        return F;  # 阻止连接
    }
    if (c$id$resp_h in blacklist) {
        action = "block";
        return F;
    }
    return T;
}

# 白名单检查
hook ConnectionFilterHook(c: connection, action: string) &priority=5 {
    if (c$id$orig_h in whitelist) {
        action = "allow";
        return T;  # 明确允许
    }
}

# 时间策略检查
hook ConnectionFilterHook(c: connection, action: string) &priority=0 {
    local hour = strftime("%H", current_time());
    if (hour >= "22" || hour < "06") {
        # 夜间禁止非白名单连接
        if (c$id$orig_h !in whitelist) {
            action = "block";
            return F;
        }
    }
    return T;
}

# 使用
event connection_established(c: connection) {
    local action = "allow";

    if (hook ConnectionFilterHook(c, action)) {
        if (action == "allow") {
            # 允许连接
        } else {
            # 阻止连接
        }
    }
}
```

### 8.2 协议分析器启用控制

```zeek
# 基于连接元数据决定是否启用特定分析器
type AnalyzerEnableHook: hook(c: connection, analyzer: string);

hook AnalyzerEnableHook(c: connection, analyzer: string) &priority=10 {
    # 禁止对私有 IP 启用加密分析
    if (analyzer == "SSL" && is_private_ip(c$id$resp_h)) {
        return F;
    }
    return T;
}

hook AnalyzerEnableHook(c: connection, analyzer: string) &priority=5 {
    # 禁止对特定端口启用 FTP 分析
    if (analyzer == "FTP" && c$id$resp_p !in 21/tcp) {
        return F;
    }
    return T;
}
```

---

## 9. Hook 与 C++ 插件

### 9.1 C++ 层 Hook 调用

```cpp
// src/my-plugin/MyAnalyzer.cc

#include "Hook.h"
#include "HookManager.h"

// 定义 hook 类型
class MyHookType : public zeek::Hook {
public:
    MyHookType() : Hook("my_hook_type") {}

    bool Run(int arg1, const char* arg2) {
        // 调用所有注册的 ZeekScript 处理程序
        auto handlers = zeek::HookManager::GetHandlers("my_hook_type");
        for (auto& handler : handlers) {
            if (!handler->Execute(arg1, arg2)) {
                return false;  // 短路
            }
        }
        return true;
    }
};

// 全局 hook 实例
static MyHookType g_my_hook;

// 触发 hook
void MyAnalyzer::SomeEvent() {
    if (!g_my_hook.Run(42, "test")) {
        // Hook 中断，不继续
        return;
    }

    // 继续正常处理
}
```

### 9.2 注册 ZeekScript 处理程序

```zeek
# ZeekScript 端注册处理程序
hook MyHookType(arg1: int, arg2: string): bool {
    print fmt("Hook called with %d, %s", arg1, arg2);
    return T;  # 继续执行
}
```

---

## 10. Hook 性能考虑

### 10.1 Hook 开销

- Hook 调用比普通函数调用**开销更高**（需要遍历处理程序列表）
- 对于性能敏感路径，避免频繁调用 hook

### 10.2 优化建议

```zeek
# 避免在 hot path 中使用 hook
# 改为：先收集数据，最后统一调用 hook

# 不推荐（在数据包事件中频繁调用）
event packet(p: raw_pkt) {
    hook MyHook(p);  # 每包调用，开销大
}

# 推荐（批量处理后调用）
global pending_packets: vector of raw_pkt;

event packet(p: raw_pkt) {
    pending_packets += p;
}

event every_1_sec() {
    if (|pending_packets| > 0) {
        hook BatchHook(pending_packets);  # 批量调用
        pending_packets = vector();
    }
}
```

---

## 11. 本章小结

本章介绍了 Zeek 的 Hook 机制：

1. **Hook vs Event**：Hook 支持短路求值（可中断），Event 是广播式（全部执行）
2. **Hook 类型**：用 `type` 关键字定义 hook 类型
3. **Hook 处理程序**：`hook` 关键字定义处理程序，支持 `&priority`
4. **Hook 调用**：用 `hook HookType(args)` 显式调用
5. **break vs return F**：break 立即停止 hook 链，return F 仅返回 False 但继续执行
6. **内置 Hooks**：zeek_done、Intel::MatchHook、Log::rotation_hook 等
7. **使用场景**：访问控制、条件日志、协议分析器启用控制
8. **C++ 集成**：可在 C++ 插件中定义和调用 hook

**下一章**将介绍 **Packages**——Zeek 的脚本组织和包管理机制，包括 `@load`、ZKG（Zeek Package Manager）和脚本模块化。

> [!tip] 延伸阅读
>
> - [Zeek Hook Documentation](https://docs.zeek.org/en/stable/script-reference/)
> - [Zeek Script Loading](https://docs.zeek.org/en/stable/scripts/base/frameworks/scripts/)
