---
title: "Zeek 深度探索 (二十四)：Notice 框架"
date: 2026-04-15
tags:
  - zeek
  - series
  - notice
  - notice.log
  - alert
  - security
description: "深入解析 Zeek Notice 框架——Notice::Info、告警处理、notice.log、Notice 策略、通知动作"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
>
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
> 11. [[2026-04-15-zeek-deep-dive-ch11-http|第十一章：HTTP 分析]]
> 12. [[2026-04-15-zeek-deep-dive-ch12-dns|第十二章：DNS 分析]]
> 13. [[2026-04-15-zeek-deep-dive-ch13-tls|第十三章：TLS 分析]]
> 14. [[2026-04-15-zeek-deep-dive-ch14-smb|第十四章：SMB 分析]]
> 15. [[2026-04-15-zeek-deep-dive-ch15-ssh|第十五章：SSH 分析]]
> 16. [[2026-04-15-zeek-deep-dive-ch16-ftp|第十六章：FTP 分析]]
> 17. [[2026-04-15-zeek-deep-dive-ch17-smtp|第十七章：SMTP 分析]]
> 18. [[2026-04-15-zeek-deep-dive-ch18-rdp|第十八章：RDP 分析]]
> 19. [[2026-04-15-zeek-deep-dive-ch19-kafka|第十九章：Kafka 集成]]
> 20. [[2026-04-15-zeek-deep-dive-ch20-conn|第二十章：连接分析]]
> 21. [[2026-04-15-zeek-deep-dive-ch21-weirds|第二十一章：Weird 日志]]
> 22. [[2026-04-15-zeek-deep-dive-ch22-files|第二十二章：文件分析]]
> 23. [[2026-04-15-zeek-deep-dive-ch23-signatures|第二十三章：签名检测]]
> 24. **第二十四章：Notice 框架**

---

## 1. Notice 框架概述

Notice 框架是 Zeek 的告警和通知系统，用于生成安全告警、操作员通知和自动化响应。

### 1.1 Notice 框架位置

```
$ZEEK_HOME/scripts/base/frameworks/notice/
├── main.zeek           # Notice 主框架
├── types.zeek          # Notice::Info 等类型
├── actions.zeek        # 动作定义
├── policy.zeek         # 策略处理
└── ...

$ZEEK_HOME/scripts/policy/misc/
├── detect-web-attacks.zeek  # Web 攻击检测
├── scan.zeek               # 扫描检测
└── ...
```

### 1.2 Notice 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Notice 架构                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Security Event (签名匹配/异常检测/威胁情报)                    │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  NOTICE() 函数调用                                     │  │
│  │  Notice::policy 匹配                                   │  │
│  │  Action 执行                                           │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Notice::Info record                                   │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  notice.log + Action Outputs (Email/Slack/Syslog)             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. Notice 日志格式

### 2.1 notice.log 字段详解

```zeek
type Notice::Info = record {
    # 时间戳
    ts: time;              # 时间戳
    uid: string &optional;  # 连接 UID（如适用）
    id: conn_id &optional;  # 4-tuple（如适用）

    # Notice 标识
    note: Notice::Type;    # Notice 类型
    msg: string;           # 消息
    sub: string &optional;  # 子消息
    data: string &optional;  # 额外数据

    # 来源
    src: addr &optional;   # 源地址（如适用）
    dst: addr &optional;   # 目标地址（如适用）

    # 连接
    conn: connection &optional;  # 连接对象

    # 文件
    f: fa_file &optional;   # 文件对象

    # n: count &optional;  # 重复次数

    # Actions
    actions: set[Notice::Action];  # 执行的动作
    email_body_sections: vector of string;  # 邮件内容

    # 元数据
    identifier: string &optional;  # 用于分组/去重的标识符
    dest: string &optional;  # 目标描述

    # Suppression
    suppress_for: interval &optional;  # 抑制时长
    remote: bool &optional;  # 是否来自远程
};
```

### 2.2 notice.log 示例

```
#fields ts uid id.orig_h id.orig_p id.resp_h id.resp_p note msg actions dest
1672531200.123456 Cx1234abcd 192.168.1.100 52341 93.184.216.34 443 HTTP::SQL_INJECTION "SQL injection attempt detected" [Notice::ACTION_LOG, Notice::ACTION_ALARM] 93.184.216.34
```

### 2.3 主要字段说明

| 字段           | 类型                | 说明             |
| -------------- | ------------------- | ---------------- |
| `ts`           | time                | 时间戳           |
| `uid`          | string              | 关联连接 UID     |
| `id`           | conn_id             | 关联连接 4-tuple |
| `note`         | Notice::Type        | Notice 类型      |
| `msg`          | string              | 主消息           |
| `sub`          | string              | 子消息           |
| `src`          | addr                | 源地址           |
| `dst`          | addr                | 目标地址         |
| `actions`      | set[Notice::Action] | 执行的动作       |
| `identifier`   | string              | 去重标识符       |
| `suppress_for` | interval            | 抑制时长         |

---

## 3. Notice 类型

### 3.1 内置 Notice 类型

```zeek
# 连接相关
type Notice::Type = enum {
    Connection::SYN_Scan,           # SYN 扫描
    Connection::AddressScan,         # 地址扫描
    Connection::PortScan,            # 端口扫描
    Connection::PartialAddressScan,  # 部分地址扫描
    Connection::WhiteOrphaned,       # 孤立连接
    Connection::UnknownProtocol,     # 未知协议
    Connection::饱和攻击,             # 饱和攻击
    Connection::SensitiveProtocol,    # 敏感协议

    # SSH 相关
    SSH::BruteForce,               # SSH 暴力破解
    SSH::Login,                    # SSH 登录
    SSH::InterestingHostnames,      # 感兴趣的主机名

    # HTTP 相关
    HTTP::SQL_INJECTION,           # SQL 注入
    HTTP::XSS,                    # XSS
    HTTP::CommandInjection,        # 命令注入
    HTTP::SuspiciousHTTP,         # 可疑 HTTP

    # SMB 相关
    SMB::SuccessfulAuthentication,  # 成功认证
    SMB::FailedAuthentication,      # 失败认证

    # SSL/TLS 相关
    SSL::InvalidServerCert,        # 无效证书
    SSL::ExpensiveCipher,          # 高成本加密
    SSL::WeakCipher,               # 弱加密

    # 文件相关
    Files::Malware,                # 恶意软件
    Files::Suspicious,             # 可疑文件

    # 扫描相关
    Scan::PortScan,               # 端口扫描
    Scan::AddressScan,            # 地址扫描

    # 通用
    Weird::Activity,               # Weird 活动
    Talk::Subscribe,              # Talk 订阅

    # 自定义
    MyCustom::Notice,              # 自定义 Notice
};
```

### 3.2 自定义 Notice 类型

```zeek
# 定义新的 Notice 类型
module MyCustom;

export {
    redef enum Notice::Type += {
        MyCustom::SuspiciousActivity,  # 可疑活动
        MyCustom::DataExfiltration,    # 数据泄露
        MyCustom::C2Communication,     # C2 通信
    };
}
```

---

## 4. Notice 动作

### 4.1 动作类型

```zeek
type Notice::Action: enum {
    ACTION_LOG,       # 记录到日志
    ACTION_ALARM,     # 触发告警
    ACTION_EMAIL,     # 发送邮件
    ACTION_DROP,      # 丢弃连接（需要配合其他系统）
    ACTION_NONE       # 无动作
};
```

### 4.2 动作优先级

当多个动作应用于一个 Notice 时：

1. `ACTION_DROP` 优先
2. `ACTION_ALARM` 其次
3. `ACTION_EMAIL` 再次
4. `ACTION_LOG` 最后

---

## 5. 触发 Notice

### 5.1 NOTICE 函数

```zeek
NOTICE([$note = Notice::Type, $msg = string, ...])
```

最简单的触发方式：

```zeek
event connection_attempted(c: connection)
    {
    NOTICE([$note = Connection::SYN_Scan,
            $msg = fmt("SYN scan detected from %s", c$id$orig_h),
            $conn = c]);
    }
```

### 5.2 完整 Notice 参数

```zeek
NOTICE([$note = HTTP::SQL_INJECTION,
        $msg = "SQL injection attempt detected",
        $sub = fmt("Target: %s", c$id$resp_h),
        $conn = c,
        $src = c$id$orig_h,
        $dst = c$id$resp_h,
        $identifier = fmt("%s-%s", c$id$orig_h, c$id$resp_h),
        $suppress_for = 10min,
        $actions = set(Notice::ACTION_LOG, Notice::ACTION_ALARM)])
```

### 5.3 条件触发

```zeek
event http_request(c: connection, method: string, original_uri: string, version: string)
    {
    # 检测 SQL 注入
    if (/union\s+select|\'\s+or\s+\'/i in original_uri) {
        NOTICE([$note = HTTP::SQL_INJECTION,
                $msg = fmt("SQL injection attempt: %s", original_uri),
                $conn = c,
                $identifier = fmt("sql-inj-%s", c$id$orig_h)]);
    }
    }
```

---

## 6. Notice 策略

### 6.1 策略框架

```zeek
# Notice::policy 是一个表，存储所有策略规则
global Notice::policy: table[Notice::Type] of Notice::Policy;
```

### 6.2 Policy 结构

```zeek
type Notice::Policy = record {
    # 匹配条件
    pred: function(n: Notice::Info): bool;  # 谓词函数
    pred_change: function(n: Notice::Info): bool;  # 变化谓词

    # 动作
    action: function(n: Notice::Info): Notice::Action;  # 动作函数

    # 输出
    dest: Notice::Destination;  # 目的地
    identifier: string &optional;  # 标识符

    # 抑制
    suppress_for: interval &optional;  # 抑制时长
    expire: interval &optional;  # 过期时间

    # 可扩展性
    group: string &optional;  # 组名
    by: string &optional;  # 分组键
};
```

### 6.3 策略示例

```zeek
# 为特定 Notice 类型定义策略
redef Notice::policy += {
    [$note = SSH::BruteForce,
     $pred(n: Notice::Info) = { return T; },
     $action(n: Notice::Info) = { return Notice::ACTION_ALARM; },
     $suppress_for = 10min],

    [$note = HTTP::SQL_INJECTION,
     $pred(n: Notice::Info) = { return T; },
     $action(n: Notice::Info) = { return Notice::ACTION_ALARM; },
     $suppress_for = 1hr]
};
```

### 6.4 复杂策略

```zeek
# 根据条件决定动作
redef Notice::policy += {
    [$note = Connection::SYN_Scan,
     $pred(n: Notice::Info) = {
         # 只对外部源到内部目标的扫描告警
         return n?$src && n?$dst && Site::is_private_addr(n$src) == F &&
                Site::is_private_addr(n$dst) == T;
     },
     $action(n: Notice::Info) = {
         # 如果 5 分钟内超过 100 次，则升级为 ALARM
         return Notice::ACTION_LOG;
     }]
};
```

---

## 7. Notice 事件

### 7.1 Notice 事件

```zeek
event Notice::notice(n: Notice::Info)
```

每个 Notice 触发时都会调用此事件。

```zeek
event Notice::notice(n: Notice::Info)
    {
    print fmt("[NOTICE] %s: %s", n$note, n$msg);

    # 记录到单独的文件
    if (n$note == SSH::BruteForce) {
        print fmt("%s | SSH Brute Force | %s", n$ts, n$msg) to open("/var/log/zeek/ssh-brute.log");
    }
    }
```

### 7.2 Notice_policy 事件

```zeek
event Notice::policy(n: Notice::Info, p: Notice::Policy)
```

在策略匹配后、动作执行前调用。

```zeek
event Notice::policy(n: Notice::Info, p: Notice::Policy)
    {
    print fmt("[POLICY] Policy matched for %s", n$note);

    # 可以修改 Notice 内容
    if (n$note == HTTP::SQL_INJECTION) {
        print fmt("[ALERT] Critical: %s", n$msg);
    }
    }
```

### 7.3 Notice_action 事件

```zeek
event Notice::action(n: Notice::Info, action: Notice::Action)
```

动作执行时调用。

```zeek
event Notice::action(n: Notice::Info, action: Notice::Action)
    {
    print fmt("[ACTION] Executing action %s for %s", action, n$note);
    }
```

---

## 8. Notice 配置

### 8.1 邮件配置

```zeek
# 邮件配置
redef Notice::mail_dest = "security@example.com";
redef Notice::mail_subject_prefix = "[Zeek Alert]";

# 邮件星星
redef Notice::body_header = "Zeek Notice Report";
redef Notice::body_footer = "Generated by Zeek";
```

### 8.2 抑制配置

```zeek
# 默认抑制时长
redef Notice::default_suppress_for = 10min;

# 特定 Notice 的抑制
redef Notice::suppress_suppression: table[Notice::Type] of interval = {
    [SSH::BruteForce] = 30min,
    [Connection::SYN_Scan] = 5min,
    [HTTP::SQL_INJECTION] = 1hr,
};
```

### 8.3 输出配置

```zeek
# 日志文件名
redef Notice::notice_log = "notice";

# 是否记录所有 Notice
redef Notice::log_all_notices = F;

# 只记录特定动作的 Notice
redef Notice::log_actions: set[Notice::Action] = { Notice::ACTION_LOG, Notice::ACTION_ALARM };
```

---

## 9. Notice 实战

### 9.1 SSH 暴力破解检测

```zeek
global ssh_failures: table[addr] of count;

event ssh_auth_unsuccessful(c: connection)
    {
    local src = c$id$orig_h;

    if (src !in ssh_failures) {
        ssh_failures[src] = 0;
    }
    ssh_failures[src] += 1;

    if (ssh_failures[src] >= 5) {
        NOTICE([$note = SSH::BruteForce,
                $msg = fmt("SSH brute force from %s: %d failures", src, ssh_failures[src]),
                $conn = c,
                $identifier = fmt("ssh-brute-%s", src),
                $suppress_for = 1hr]);

        # 重置计数
        delete ssh_failures[src];
    }
    }
```

### 9.2 数据泄露检测

```zeek
event file_state_remove(f: fa_file)
    {
    # 检测大文件外传
    if (f$size > 100MB && f?$mime) {
        NOTICE([$note = MyCustom::DataExfiltration,
                $msg = fmt("Large file transfer detected: %s (size: %d MB)",
                          f?$filename ? f$filename : f$fuid, f$size / 1MB),
                $identifier = fmt("large-file-%s", f$fuid),
                $suppress_for = 30min]);
    }
    }
```

### 9.3 C2 通信检测

```zeek
# 检测可疑域名
global suspicious_domains = set(
    "evil.com",
    "c2.malware.com",
    "badness. attacker.com"
);

event dns_query(c: connection, query: string, query_type: count)
    {
    local query_lower = to_lower(query);

    for (domain in suspicious_domains) {
        if (query_lower == domain || query_lower has_suffix("." + domain)) {
            NOTICE([$note = MyCustom::C2Communication,
                    $msg = fmt("C2 communication suspected: %s", query),
                    $conn = c,
                    $identifier = fmt("c2-%s", query)]);
        }
    }
    }
```

### 9.4 横向移动检测

```zeek
# 检测同一源访问多个目标
global source_targets: table[addr] of set[addr];

event smtp_sent(c: connection, from: string, to: set[string], subject: string, body: string)
    {
    local src = c$id$orig_h;

    if (src !in source_targets) {
        source_targets[src] = set();
    }

    for (dest_host in c$service) {
        add source_targets[src][dest_host];
    }

    # 同一源访问超过 10 个目标
    if (|source_targets[src]| > 10) {
        NOTICE([$note = MyCustom::SuspiciousActivity,
                $msg = fmt("Possible lateral movement: %s accessed %d hosts",
                          src, |source_targets[src]|),
                $conn = c,
                $suppress_for = 1hr]);
    }
    }
```

---

## 10. Notice 与其他框架联动

### 10.1 与 Intelligence 联动

```zeek
@load frameworks/intel

event intel_cached_match(s: string, items: set[Intel::Item])
    {
    for (item in items) {
        NOTICE([$note = Intel::match,
                $msg = fmt("Intelligence match: %s (%s)", s, item$meta$desc),
                $identifier = fmt("intel-%s", s)]);
    }
    }
```

### 10.2 与签名联动

```zeek
event signature_match(state: signature_state, data: signature_event_data)
    {
    # 根据签名严重程度决定 Notice 类型
    local note_type: Notice::Type;

    if (state$sig_id == "3000001" || state$sig_id == "3000002") {
        note_type = HTTP::CommandInjection;
    } else if (state$sig_id == "4000001" || state$sig_id == "4000002") {
        note_type = HTTP::SQL_INJECTION;
    } else {
        note_type = HTTP::SuspiciousHTTP;
    }

    NOTICE([$note = note_type,
            $msg = fmt("Signature %s matched: %s", state$sig_id, state$msg),
            $conn = data$c,
            $identifier = fmt("sig-%s", state$sig_id)]);
    }
```

### 10.3 与文件分析联动

```zeek
event file_hash(f: fa_file, kind: string, hash: string)
    {
    if (kind == "sha256" && hash in malicious_hashes) {
        NOTICE([$note = Files::Malware,
                $msg = fmt("Known malware detected: SHA256=%s", hash),
                $f = f,
                $identifier = fmt("malware-%s", hash),
                $suppress_for = 1day]);
    }
    }
```

---

## 11. Notice 输出扩展

### 11.1 Syslog 输出

```zeek
# 发送到 syslog
redef Notice::syslog_dest = "localhost:514";

# 配置 syslog 设施
redef Notice::syslog_facility = SYSLOG_LOCAL3;
```

### 11.2 Webhook 输出

```zeek
# 使用 @load-sigs 或自定义脚本发送 webhook
event Notice::notice(n: Notice::Info)
    {
    # 发送到 Slack
    if (n$note == SSH::BruteForce || n$note == HTTP::SQL_INJECTION) {
        local payload = fmt("{\"text\": \"[Zeek Alert] %s: %s\"}", n$note, n$msg);
        # 发送 HTTP POST 请求
    }
    }
```

### 11.3 自定义输出

```zeek
event Notice::notice(n: Notice::Info)
    {
    # 输出到文件
    local f = open("/var/log/zeek/security-alerts.json");
    print f, to_json(n);
    close(f);

    # 发送到外部系统
    # system(fmt("python3 send_alert.py '%s'", n$msg));
    }
```

---

## 12. 小结

本章介绍了 Zeek Notice 框架的核心能力：

| 组件               | 说明                            |
| ------------------ | ------------------------------- |
| **notice.log**     | 安全告警主日志                  |
| **Notice::Info**   | Notice 信息的 record 类型       |
| **NOTICE()**       | 触发 Notice 的主要函数          |
| **Notice::policy** | Notice 处理策略表               |
| **Notice::Action** | 动作类型 (LOG/ALARM/EMAIL/DROP) |
| **suppress_for**   | 抑制时长，防止重复告警          |

Notice 类型分类：

- 连接类 (Connection::\*)
- SSH 类 (SSH::\*)
- HTTP 类 (HTTP::\*)
- SSL 类 (SSL::\*)
- 文件类 (Files::\*)

Notice 框架的价值：

- 统一的安全告警系统
- 灵活的策略配置
- 支持多种输出方式
- 与 Zeek 其他框架深度集成

Notice 最佳实践：

- 为不同 Notice 类型设置合适的 suppress_for
- 使用 identifier 进行去重
- 合理配置 Notice::policy
- 定期审查 Notice 日志

通过 Notice 框架，可以构建完整的安全运营工作流，实现从检测到响应的自动化。
