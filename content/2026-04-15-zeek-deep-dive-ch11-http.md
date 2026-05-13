---
title: "Zeek 深度探索 (十一)：HTTP 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - http
  - protocol-analysis
  - web
description: "深入解析 Zeek HTTP 分析器——HTTP::Info record、请求/响应日志、头部解析、User-Agent 分析、HTTP 脚本事件"
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
> 10. [[2026-04-15-zeek-deep-dive-ch10-debugging|第十章：调试]]
> 11. **第十一章：HTTP 分析**

---

## 1. HTTP 分析器概述

Zeek 内置完整的 HTTP/1.x 协议解析器，位于 `base/protocols/http` 目录。HTTP 分析器是 Zeek 日志输出最丰富的协议分析器之一，几乎每个生产环境都会关注 HTTP 日志。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/http/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # HTTP::Info 等类型定义
├── entities.zeek      # HTTP entity 处理
├── var-dirs.zeek      # URI/HTTP Header 变量处理
└── plugins/           # HTTP 分析器插件
```

### 1.2 HTTP 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    HTTP 分析器架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection                                              │
│       ↓                                                      │
│  HTTP Body Parser (Content-Length / Chunked)               │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  http_request  事件 (method, uri, version, headers)  │  │
│  │  http_reply    事件 (version, status, reason, headers)│  │
│  │  http_header   事件 (header name, value)               │  │
│  │  http_entity   事件 (entity data)                      │  │
│  │  http_all_headers 事件 (全部头部)                      │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  HTTP::Info record 填充                                     │
│       ↓                                                      │
│  http.log 输出                                               │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. HTTP 日志格式

### 2.1 http.log 字段详解

```zeek
type HTTP::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;            # 连接 UID
    id: conn_id;           # 4-tuple (orig_h, orig_p, resp_h, resp_p)

    # 请求信息
    method: string;         # GET/POST/PUT/DELETE/HEAD/OPTIONS
    host: string;           # Host 头部
    uri: string;            # 请求 URI
    referrer: string;       # Referer 头部
    version: string;        # HTTP 版本

    # 请求头部
    user_agent: string;     # User-Agent 头部
    request_body_len: count;# 请求 body 长度
    response_body_len: count;# 响应 body 长度

    # 响应信息
    status_code: count;     # 状态码 (200/404/500 等)
    status_msg: string;     # 状态消息 (OK/Not Found 等)

    # 响应头部
    resp_fuids: vector of string;  # 响应中文件的文件 UID
    resp_mime_types: vector of string; # MIME 类型

    # 内部字段
    orig_fuids: vector of string;
    orig_mime_types: vector of string;
    missing_headers: vector of string;

    # 客户端信息
    client_header_names: vector of string;
    server_header_names: vector of string;

    # 统计
    orig_bytes: count;      # 原始方向字节数
    resp_bytes: count;      # 响应方向字节数
    username: string &log &optional; # HTTP 认证用户名
    password: string &log &optional; # HTTP 认证密码
};
```

### 2.2 http.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	method	host	uri	referrer	version	user_agent	origin	request_body_len	response_body_len	status_code	status_msg	username	password
1672531200.123456	Cx1234abcd	192.168.1.100	52341	93.184.216.34	80	GET	example.com	/index.html	-	1.1	Mozilla/5.0	-	0	342	200	OK	-	-
1672531210.234567	Dy5678efgh	192.168.1.100	52342	93.184.216.34	80	POST	api.example.com	/api/login	-	1.1	curl/7.68.0	-	48	128	200	OK	admin	secret123
```

---

## 3. HTTP 脚本事件

### 3.1 http_request 事件

```zeek
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
```

触发时机：解析完 HTTP 请求行后。

```zeek
# 记录所有 POST 请求
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
    {
    if (method == "POST") {
        print fmt("[%s] POST to %s from %s", c$uid, unescaped_URI, c$id$orig_h);
    }
    }

# 检测敏感路径访问
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
    {
    local sensitive_paths = /\/admin|\/config|\/wp-login|\/phpmyadmin/;
    if (sensitive_paths in unescaped_URI) {
        Notice::weird("Sensitive path access", c);
    }
    }
```

### 3.2 http_reply 事件

```zeek
event http_reply(c: connection, version: string, code: count,
                 reason: string, headers: mime_header_list)
```

触发时机：解析完 HTTP 响应行后。

```zeek
# 检测异常状态码
event http_reply(c: connection, version: string, code: count,
                 reason: string, headers: mime_header_list)
    {
    # 检测可能是 webshell 的响应
    if (code == 200 && c$http$uri == /.*\.(php|asp|jsp)$/) {
        print fmt("Suspicious: %s accessed %s", c$id$orig_h, c$http$uri);
    }

    # 检测错误响应
    if (code >= 500) {
        print fmt("Server error %d: %s from %s", code, reason, c$id$resp_h);
    }
    }
```

### 3.3 http_all_headers 事件

```zeek
event http_all_headers(header_names: vector of string,
                       header_values: vector of string)
```

触发时机：所有请求或响应头部解析完成后。

```zeek
# 提取所有头部
event http_all_headers(headertype: mime_header_type, c: connection,
                       hlist: mime_header_list)
    {
    for (h in hlist) {
        print fmt("%s: %s", hlist[h]$name, hlist[h]$value);
    }
    }
```

### 3.4 http_entity 事件

```zeek
event http_entity(c: connection, is_orig: bool, length: count,
                 data: string, mime_type: string)
```

触发时机：HTTP body 的一个 chunk 被解析后。

```zeek
# 提取 POST body 内容
event http_entity(c: connection, is_orig: bool, length: count,
                 data: string, mime_type: string)
    {
    if (is_orig && c$http?$method && c$http$method == "POST") {
        print fmt("POST body (%d bytes): %s", length, data);
    }
    }
```

---

## 4. HTTP 脚本定制

### 4.1 禁用 HTTP 分析器

```zeek
# 局部禁用
redef HTTP::disable_sql_logging = T;

# 节点配置
# node.cfg:
[worker]
base_protocols += http
```

### 4.2 User-Agent 分析

```zeek
# 识别爬虫
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
    {
    if (c$http?$user_agent) {
        local ua = c$http$user_agent;

        # 检测常见爬虫
        if (/curl|wget|python|scrapy|requests/i in ua) {
            print fmt("Bot detected: %s (%s)", ua, c$id$orig_h);
        }

        # 检测攻击工具
        if (/sqlmap|nmap|masscan|nikto|dirbuster/i in ua) {
            Notice::weird("Attack tool detected", c);
        }
    }
    }
```

### 4.3 Cookie 会话分析

```zeek
# 提取 Cookie 并追踪会话
global http_cookies: table[string] of set[string];

event http_all_headers(headertype: mime_header_type, c: connection,
                       hlist: mime_header_list)
    {
    for (h in hlist) {
        if (hlist[h]$name == "cookie") {
            local cookies = split_string(hlist[h]$value, /; /);
            for (cookie in cookies) {
                local parts = split_string(cookie, /=/);
                if (|parts| == 2) {
                    local cookie_name = parts[0];
                    local cookie_val = parts[1];

                    # 追踪 cookie
                    if (c$uid !in http_cookies) {
                        http_cookies[c$uid] = set();
                    }
                    add http_cookies[c$uid][cookie_name];
                }
            }
        }
    }
    }
```

### 4.4 检测恶意 HTTP 流量

```zeek
# 检测疑似 SSRF 攻击
event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
    {
    # 检测内网 IP 访问
    if (/http:\/\/127\.|http:\/\/localhost|http:\/\/192\.168\.|http:\/\/10\.|http:\/\/172\.(1[6-9]|2[0-9]|3[0-1])\./i in unescaped_URI) {
        NOTICE([$note = SSRF_DETECTED,
                $msg = fmt("Possible SSRF: %s accessing %s", c$id$orig_h, unescaped_URI),
                $conn = c]);
    }

    # 检测协议 smuggling
    if (/\\r\\n/i in unescaped_URI || /\\r\\n/i in original_URI) {
        NOTICE([$note = WEIRD_HTTP_URI,
                $msg = fmt("HTTP URI smuggling attempt from %s", c$id$orig_h),
                $conn = c]);
    }
    }
```

---

## 5. HTTP 配置选项

### 5.1 主要配置项

```zeek
# 日志过滤
redef HTTP::include_raw_uri = F;        # 是否在日志中包含原始 URI
redef HTTP::log_useragent = T;          # 是否记录 User-Agent
redef HTTP::log_referrer = T;           # 是否记录 Referer
redef HTTP::log_post = T;                # 是否记录 POST body

# SQL 注入检测
redef HTTP::disable_sql_logging = F;     # 禁用 SQL 日志

# 端口映射
redef HTTP::default_ports = { 80/tcp, 8080/tcp, 8000/tcp, 8888/tcp };
```

### 5.2 HTTP 端口映射

```zeek
# 添加非标准 HTTP 端口
redef HTTP::default_ports += { 3000/tcp, 5000/tcp, 8000/tcp };

# 自定义端口分析
event zeek_init() {
    Analyzer::register_for_ports(Analyzer::ANALYZER_HTTP, [80/tcp, 8080/tcp]);
}
```

---

## 6. HTTP 与文件分析

### 6.1 HTTP 文件提取

```zeek
# 启用 HTTP 文件提取
event file_new(f: fa_file) {
    if (f$source == "HTTP") {
        print fmt("HTTP file detected: %s, mime: %s", f$id, f$ mime_type);
    }
}

# 在 HTTP 响应中关联文件
event http_reply(c: connection, version: string, code: count,
                 reason: string, headers: mime_header_list)
    {
    if (c$http?$resp_fuids && |c$http$resp_fuids| > 0) {
        for (fuid in c$http$resp_fuids) {
            print fmt("Response contains file: %s", fuid);
        }
    }
    }
```

### 6.2 检测恶意文件下载

```zeek
event file_state_remove(f: fa_file) {
    if (f$source == "HTTP" && f?$mime_type) {
        # 检测可执行文件下载
        if (/application\/x-(executable|shellscript|dangerous)/ in f$mime_type) {
            NOTICE([$note = FILE_DETECTED,
                    $msg = fmt("Suspicious download: %s from %s",
                               f$id, f$http_uri),
                    $conn = f$http_conn]);
        }
    }
    }
```

---

## 7. 实战示例

### 7.1 完整 HTTP 监控脚本

```zeek
@load base/protocols/http

# HTTP 监控配置
redef HTTP::log_useragent = T;
redef HTTP::log_referrer = T;

# 威胁指标
const suspicious_methods = { "PUT", "DELETE", "TRACE", "OPTIONS" };
const suspicious_uris = /\/admin|\/wp-login|\/phpmyadmin|\/\.env|\/config/;
const attack_indicators = /union.*select|exec\(|system\(|cat\s+\/|grep\s+/i;

event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
    {
    # 检测非标准方法
    if (method in suspicious_methods) {
        NOTICE([$note = HTTP_METHOD,
                $msg = fmt("Suspicious HTTP method %s from %s to %s",
                           method, c$id$orig_h, unescaped_URI),
                $conn = c]);
    }

    # 检测敏感路径
    if (suspicious_uris in unescaped_URI) {
        print fmt("[ALERT] Sensitive path access: %s %s from %s",
                  method, unescaped_URI, c$id$orig_h);
    }

    # 检测 SQL 注入
    if (attack_indicators in unescaped_URI) {
        NOTICE([$note = SQL_INJECTION,
                $msg = fmt("Possible SQL injection from %s: %s",
                           c$id$orig_h, unescaped_URI),
                $conn = c]);
    }
    }

event http_reply(c: connection, version: string, code: count,
                 reason: string, headers: mime_header_list)
    {
    # 检测敏感文件访问
    if (code == 200 && c$http?$uri) {
        if (/\.bak$|\.sql$|\.zip$|\.tar\.gz$|\.env$/i in c$http$uri) {
            NOTICE([$note = SENSITIVE_FILE,
                    $msg = fmt("Sensitive file exposed: %s (status %d)",
                               c$http$uri, code),
                    $conn = c]);
        }
    }

    # 检测 WebShell 特征
    if (code == 200 && c$http?$resp_body_len && c$http$resp_body_len > 0) {
        # 这里需要配合 file_analysis 框架
    }
    }
```

---

## 8. 常见问题

### 8.1 HTTP 管道化请求

Zeek 支持 HTTP/1.1 管道化请求（pipelining），每个请求都会触发相应的事件。

### 8.2 分块传输编码

HTTP 分析器自动处理 `Transfer-Encoding: chunked`，`http_entity` 事件会接收完整的解码后数据。

### 8.3 连接重用

Zeek 通过 `Connection` 对象的 `c$http` 字段记录当前连接的 HTTP 状态，包括管道队列。

---

## 9. 小结

本章介绍了 Zeek HTTP 分析器的核心组件：

| 组件 | 说明 |
|------|------|
| **HTTP::Info** | HTTP 日志核心 record，包含完整请求/响应信息 |
| **http_request** | 请求解析事件，包含 method/uri/version |
| **http_reply** | 响应解析事件，包含 status_code/reason |
| **http_all_headers** | 所有头部解析完成事件 |
| **http_entity** | HTTP body 解析事件 |

HTTP 分析是 Zeek 最常用的协议分析能力，通过 `http.log` 可以进行 Web 攻击检测、用户行为分析、资产梳理等安全分析工作。
