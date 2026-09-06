---
title: "Zeek 深度探索 (二十三)：签名检测"
date: 2026-04-15
tags:
  - zeek
  - series
  - signature
  - sig.log
  - pattern-matching
  - ids
description: "深入解析 Zeek 签名检测——Sig::Info、签名框架、签名语法、自定义签名、协议检测"
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
> 21. [[ch21-weirds|第二十一章：Weird 日志]]
> 22. [[ch22-files|第二十二章：文件分析]]
> 23. **第二十三章：签名检测**

---

## 1. 签名检测概述

Zeek 的签名检测框架（Signature Framework）允许用户定义签名规则来检测特定的流量模式。签名与 Suricata 的规则类似但使用 Zeek 自己的语法。

### 1.1 签名框架位置

```
$ZEEK_HOME/scripts/base/frameworks/signatures/
├── main.zeek           # 签名主框架
├── signature-info.zeek # Sig::Info 类型
└── ...

$ZEEK_HOME/scripts/policy/protocols/
├── http/
│   └── suspicious-http-signatures.sig  # HTTP 可疑签名
└── ...
```

### 1.2 签名检测架构

```
┌─────────────────────────────────────────────────────────────┐
│                    签名检测架构                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Packet/Connection                                            │
│       ↓                                                      │
│  Signature Matcher                                            │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Signature Rules (*.sig)                              │  │
│  │  ├── Content Match                                     │  │
│  │  ├── Payload Length Match                             │  │
│  │  ├── Header Match                                     │  │
│  │  └── Context Match                                    │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  Signature Match Event                                        │
│       ↓                                                      │
│  sig.log + Notice (可选)                                      │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 签名日志格式

### 2.1 sig.log 字段详解

```zeek
type Signatures::Info = record {
    # 时间戳
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;           # 4-tuple

    # 签名标识
    sig_id: string;       # 签名 ID
    sig_name: string;      # 签名名称
    event: string;         # 触发的事件类型

    # 匹配信息
    msg: string;          # 签名消息

    # 来源
    source: string;       # 签名来源 (local/remote)
};
```

### 2.2 sig.log 示例

```
#fields ts uid id.orig_h id.orig_p id.resp_h id.resp_p sig_id sig_name event msg source
1672531200.123456 Cx1234abcd 192.168.1.100 52341 93.184.216.34 80 2000005 "HTTP suspicious port 8080" Signatures::Summary "HTTP on non-standard port" local
```

---

## 3. 签名语法

### 3.1 签名基本结构

```
signature <signature-id> <signature-name> <required-context> <expression>
```

示例：

```zeek
signature sid-1001 "HTTP Test" http {
    payload /GET \/test/,
    payload /HTTP\/1\.[01]/,
    tcp-state established
}
```

### 3.2 签名组件

#### 3.2.1 签名 ID 和名称

```zeek
signature <id> "<name>"
```

- `id`: 唯一数字标识符
- `name`: 描述性名称

#### 3.2.2 必需上下文

| 上下文 | 说明      |
| ------ | --------- |
| `http` | HTTP 协议 |
| `smtp` | SMTP 协议 |
| `dns`  | DNS 协议  |
| `ssh`  | SSH 协议  |
| `tcp`  | TCP 连接  |
| `udp`  | UDP 连接  |
| `icmp` | ICMP 包   |
| `**`   | 任何协议  |

### 3.3 匹配条件

#### 3.3.1 payload 匹配

```zeek
payload /<regex>/,
payload !/<regex>/,    # 否定
```

```zeek
# 匹配 HTTP GET 请求
signature sid-1001 "HTTP GET" http {
    payload /GET \/\S+/,
    payload /HTTP\/1\.[01]/
}

# 匹配恶意 User-Agent
signature sid-1002 "Malicious UA" http {
    payload /curl\/|wget\//,
    payload !/Mozilla\//
}
```

#### 3.3.2 payload 长度

```zeek
payload-size <operator> <value>,
```

```zeek
# 匹配大 payload
signature sid-1003 "Large HTTP POST" http {
    payload /POST/,
    payload-size > 1MB
}
```

#### 3.3.3 header 匹配

```zeek
header <protocol>.<header> /<regex>/,
```

```zeek
# 匹配特定 HTTP 头
signature sid-1004 "SQL Injection in UA" http {
    header User-Agent /union\s+select|or\s+1\s*=\s*1/i
}

# 匹配 DNS 查询类型
signature sid-1005 "DNS Tunnel Query" dns {
    header DNS::query_type /TXT|TX/,
    payload-size > 100
}
```

#### 3.3.4 ip-header 匹配

```zeek
ip-header <field> <operator> <value>
```

```zeek
# 匹配特定 TTL
signature sid-1006 "Low TTL" ip {
    ip-header TTL == 1
}
```

#### 3.3.5 连接状态

```zeek
tcp-state <state>,
```

```zeek
# 只匹配已建立的连接
signature sid-1007 "Data on Established" tcp {
    payload /data/,
    tcp-state established
}

# 匹配发起连接的客户端
signature sid-1008 "SYN Data" tcp {
    payload /data/,
    tcp-state origin
}
```

### 3.4 组合条件

#### 3.4.1 多个 payload

```zeek
signature sid-1009 "HTTP with Java" http {
    payload /HTTP\/1\.[01]/,
    payload /java/
}
```

#### 3.4.2 范围 payload

```zeek
signature sid-1010 "HTTP Suspicious" http {
    payload /\/admin\/|\/phpmyadmin\/|\/\.env/
}
```

### 3.5 事件和动作

#### 3.5.1 签名事件

```zeek
signature <id> "<name>" <context> <expression> [-> <event>]
```

默认事件：`Signatures::Summary`

```zeek
signature sid-1011 "SQL Injection" http {
    payload /union\s+select|'\s+or\s+'/i
} -> Signatures::Summary
```

#### 3.5.1 自定义事件

```zeek
signature sid-1012 "Custom Event" http {
    payload /pattern/
} -> event sql_injection_detected(c: connection, s: signature)
```

---

## 4. 签名加载

### 4.1 加载签名文件

```zeek
# 加载签名文件
@load-sigs /path/to/signatures.sig

# 加载多个签名
@load-sigs policies/protocols/http/suspicious-http-signatures.sig
```

### 4.2 签名目录

```
$ZEEK_HOME/share/zeek/base/frameworks/signatures/
├── dpd.sig          # 协议检测签名
├── http.sig         # HTTP 相关签名
└── ...

$ZEEK_HOME/share/zeek/policy/protocols/
├── http/
│   └── suspicious-http-signatures.sig
└── ...
```

### 4.3 启用签名框架

```zeek
@load base/frameworks/signatures

# 加载签名
@load-sigs policies/protocols/http/suspicious-http-signatures.sig
```

---

## 5. 签名配置

### 5.1 签名日志配置

```zeek
# 启用签名日志
redef Signatures::log_signatures = T;

# 签名日志路径
redef Signatures::signature_log = "signatures";
```

### 5.2 签名统计

```zeek
# 启用统计
redef Signatures::track_sig_stats = T;

# 每个连接的签名限制
redef Signatures::max_signature_summaries_per_connection = 100;
```

### 5.3 签名级别

```zeek
# 签名级别 (1-100)
# 影响日志详细程度
redef Signatures::sig_min_level = 1;
```

---

## 6. 签名事件处理

### 6.1 signature_match 事件

```zeek
event signature_match(state: signature_state, data: signature_event_data)
```

签名匹配时触发。

```zeek
event signature_match(state: signature_state, data: signature_event_data)
    {
    print fmt("[SIG] Signature matched: %s (id: %s)",
              state$sig_id, state$msg);

    print fmt("[SIG] Connection: %s -> %s",
              data$c$id$orig_h, data$c$id$resp_h);

    # 可以在这里触发 Notice
    if (state$sig_id == "2000005") {
        NOTICE([$note = SUSPICIOUS_HTTP,
                $msg = fmt("Suspicious HTTP: %s", state$msg),
                $conn = data$c]);
    }
    }
```

### 6.2 signature_state 类型

```zeek
type signature_state = record {
    sig_id: string;           # 签名 ID
    sig_name: string;         # 签名名称
    msg: string;              # 消息
    event: string;            # 事件类型
    subev: string;           # 子事件
    subev_msg: string;       # 子事件消息
};
```

### 6.3 signature_event_data 类型

```zeek
type signature_event_data = record {
    c: connection;           # 连接
    is_orig: bool;          # 是否原始方向
    payload: string;        # payload 数据
};
```

---

## 7. 自定义签名实战

### 7.1 检测非标准端口 HTTP

```zeek
# suspicious-http.sig

# HTTP on port 8080
signature sid-2000001 "HTTP on port 8080" http {
    payload /HTTP\/1\.[01]/,
    tcp-state established
}

# HTTP on port 8443
signature sid-2000002 "HTTP on port 8443" http {
    payload /HTTP\/1\.[01]/,
    tcp-state established
}
```

### 7.2 检测 Web Shell

```zeek
# webshell-detect.sig

# PHP webshell patterns
signature sid-3000001 "PHP eval webshell" http {
    payload /eval\s*\(\s*\$_(POST|GET|REQUEST)/i
}

signature sid-3000002 "PHP system functions" http {
    payload /system\s*\(|exec\s*\(|passthru\s*\(|shell_exec\s*\(/i
}

signature sid-3000003 "Base64 encoded PHP" http {
    payload /base64_decode\s*\(|base64_encode\s*\(/i
}

# ASP webshell patterns
signature sid-3000004 "ASP cmd shell" http {
    payload /cmd\.exe\/c\s+|Request\.Item/i
}
```

### 7.3 检测 SQL 注入

```zeek
# sql-injection.sig

signature sid-4000001 "SQL Injection UNION" http {
    payload /union\s+(all\s+)?select/i
}

signature sid-4000002 "SQL Injection OR" http {
    payload /\bor\s+['"]?\d+['"]?\s*=\s*['"]?\d+['"]?/i
}

signature sid-4000003 "SQL Injection quotes" http {
    payload /['"]\s+(or|and)\s+['"]/i
}

signature sid-4000004 "SQL Injection comment" http {
    payload /--\s*$|\/\*.*\*\//i
}
```

### 7.4 检测数据泄露

```zeek
# data-exfiltration.sig

# 大文件外传
signature sid-5000001 "Large HTTP upload" http {
    payload /POST\/upload/i,
    payload-size > 10MB
}

# DNS 隧道检测
signature sid-5000002 "Long DNS TXT query" dns {
    header DNS::query_type /TXT/,
    payload-size > 200
}

# 敏感文件访问
signature sid-5000003 "Sensitive file access" http {
    payload /\/(etc\/passwd|\.env|\.git\/config|wp-config\.php)/i
}
```

### 7.5 检测恶意软件通信

```zeek
# malware-c2.sig

# Cobalt Strike beacon
signature sid-6000001 "Cobalt Strike C2" http {
    payload /\/__gb\/|\/submit\.php|\/cdn\/cgiserver\?/i
}

# Metasploit
signature sid-6000002 "Metasploit C2" http {
    payload /\/ Meterpreter\/|\/RDEBUG\/|\/cgi-bin\/\.cgi/i
}

# Emotet
signature sid-6000003 "Emotet C2" http {
    payload /\/wp-content\/.*\.php\?.*=/i,
    payload-size < 1000
}
```

---

## 8. 签名与 Notice 联动

### 8.1 自动联动

```zeek
# 在签名中添加 Notice 要求
signature sid-7000001 "Critical Alert" http {
    payload /malicious_pattern/
} -> Notice
```

### 8.2 签名处理脚本

```zeek
@load base/frameworks/signatures

event signature_match(state: signature_state, data: signature_event_data)
    {
    # 根据签名 ID 决定动作
    switch (state$sig_id) {
        "2000001":
            # 低危
            print fmt("[INFO] Non-standard port HTTP: %s", data$c$id$resp_h);
            break;
        "3000001", "3000002", "3000003", "3000004":
            # 高危 - Web shell
            NOTICE([$note = WEBSHELL_DETECTED,
                    $msg = fmt("Web shell detected: %s", state$msg),
                    $conn = data$c]);
            break;
        "4000001", "4000002", "4000003", "4000004":
            # 高危 - SQL 注入
            NOTICE([$note = SQL_INJECTION,
                    $msg = fmt("SQL injection detected: %s", state$msg),
                    $conn = data$c]);
            break;
    }
    }
```

---

## 9. 签名性能优化

### 9.1 避免复杂正则

```zeek
# 不推荐 - 复杂正则
signature sid-9000001 "Complex regex" http {
    payload /^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,61}[a-z0-9]$/i
}

# 推荐 - 简单匹配
signature sid-9000002 "Simple pattern" http {
    payload /\.exe$|\.dll$|\.bat$/
}
```

### 9.2 使用 payload 限制

```zeek
# 只在特定条件下匹配
signature sid-9000003 "Optimized match" http {
    payload /malware/,
    payload-size < 10KB
}
```

### 9.3 连接状态过滤

```zeek
# 减少匹配的连接数
signature sid-9000004 "State filtered" tcp {
    payload /pattern/,
    tcp-state established
}
```

---

## 10. 小结

本章介绍了 Zeek 签名检测框架：

| 组件                 | 说明                   |
| -------------------- | ---------------------- |
| **sig.log**          | 签名匹配日志           |
| **Signatures::Info** | 签名信息的 record 类型 |
| **signature_match**  | 签名匹配事件           |
| **@load-sigs**       | 加载签名文件           |
| **payload**          | payload 内容匹配       |
| **header**           | 协议头匹配             |
| **tcp-state**        | TCP 状态过滤           |

签名语法核心要素：

- `signature <id> "<name>" <context> { <conditions> }`
- `payload /<regex>/` - payload 匹配
- `header <proto>.<header> /<regex>/` - header 匹配
- `tcp-state <state>` - 连接状态过滤

签名检测的价值：

- 检测协议混淆和规避
- 发现恶意流量模式
- 补充协议分析器的检测能力
- 与威胁情报联动

签名与 Suricata 规则的区别：

- Zeek 签名使用 ZeekScript 语法
- 支持更灵活的事件处理
- 与 Zeek 事件系统深度集成

下一章我们将讨论 Notice 框架——Zeek 的告警和通知系统。
