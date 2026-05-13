---
title: "Zeek 深度探索 (十七)：SMTP 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - smtp
  - email
  - mail
  - attachment
  - protocol-analysis
description: "深入解析 Zeek SMTP 分析器——SMTP::Info record、邮件头解析、附件提取、垃圾邮件检测、SMTP 脚本事件"
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
> 11. [[2026-04-15-zeek-deep-dive-ch11-http|第十一章：HTTP 分析]]
> 12. [[2026-04-15-zeek-deep-dive-ch12-dns|第十二章：DNS 分析]]
> 13. [[2026-04-15-zeek-deep-dive-ch13-tls|第十三章：TLS 分析]]
> 14. [[2026-04-15-zeek-deep-dive-ch14-smb|第十四章：SMB 分析]]
> 15. [[2026-04-15-zeek-deep-dive-ch15-ssh|第十五章：SSH 分析]]
> 16. [[2026-04-15-zeek-deep-dive-ch16-ftp|第十六章：FTP 分析]]
> 17. **第十七章：SMTP 分析**

---

## 1. SMTP 分析器概述

Zeek 内置 SMTP 协议解析器，位于 `base/protocols/smtp` 目录。SMTP 分析器可以解析邮件头、提取附件、检测恶意邮件。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/smtp/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # SMTP::Info 等类型定义
├── content.zeek       # 邮件内容处理
└── ...
```

### 1.2 SMTP 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SMTP 分析器架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection (Port 25/587/465)                           │
│       ↓                                                      │
│  SMTP Command Parser (MAIL/RCPT/DATA/BODY)                  │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  smtp_request     事件 (command, arg)                  │  │
│  │  smtp_reply       事件 (code, msg)                      │  │
│  │  smtp_message     事件 (header, body)                   │  │
│  │  smtp_entity_data 事件 (entity data)                  │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  SMTP::Info record + mail.log + files.log                   │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. SMTP 日志格式

### 2.1 smtp.log 字段详解

```zeek
type SMTP::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;          # 4-tuple

    # 连接信息
    trans_depth: count;    # 事务深度
    helo: string;          # HELO/EHLO 字符串
    mailfrom: string;      # 发件人
    rcptto: vector of string;  # 收件人列表
    response_code: count;  # 响应码
    response_msg: string; # 响应消息
    last_reply: string;    # 最后响应

    # 邮件内容
    subject: string;       # 邮件主题
    from: string;          # From 头
    to: vector of string;  # To 头
    cc: vector of string;  # Cc 头
    reply_to: string;      # Reply-To 头
    message_id: string;    # Message-ID
    in_reply_to: string;  # In-Reply-To
    x_originating_ip: addr; # 原始发送 IP
    first_received: string; # 第一个 Received 头
    last_received: string;  # 最后一个 Received 头

    # 附件
    has_attachment: bool;  # 是否有附件
    num_attachment: count;# 附件数量
    attachment_lost: bool;  # 附件是否丢失
    files: vector of string;  # 附件文件名列表

    # tls: bool;           # 是否使用 TLS
    # fuel: string;        # FUEL 协议

    # 路径
    path: string;          # SMTP 路径
};
```

### 2.2 smtp.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	trans_depth	helo	mailfrom	rcptto	response_code	response_msg	subject	from	to	has_attachment	num_attachment
1672531200.123456	Cx1234abcd	192.168.1.100	52341	192.168.1.10	25	1	mail.example.com	sender@example.com	["recipient@example.com"]	250	OK	Invoice #1234	sender@example.com	["recipient@example.com"]	T	1
```

---

## 3. SMTP 脚本事件

### 3.1 smtp_request 事件

```zeek
event smtp_request(c: connection, command: string, arg: string)
```

触发时机：SMTP 命令被解析。

```zeek
# 监控 SMTP 命令
event smtp_request(c: connection, command: string, arg: string)
    {
    print fmt("[SMTP] %s %s", command, arg);

    # 检测特定命令
    if (command == "MAIL") {
        print fmt("[SMTP] From: %s", arg);
    }
    if (command == "RCPT") {
        print fmt("[SMTP] To: %s", arg);
    }
    }
```

### 3.2 smtp_reply 事件

```zeek
event smtp_reply(c: connection, code: count, msg: string, cont_resp: bool)
```

触发时机：SMTP 响应被解析。

```zeek
# 监控 SMTP 响应
event smtp_reply(c: connection, code: count, msg: string, cont_resp: bool)
    {
    print fmt("[SMTP] Response %d: %s", code, msg);

    # 检测错误
    if (code >= 500) {
        print fmt("[SMTP] SMTP error: %s", msg);
    }
    }
```

### 3.3 smtp_message 事件

```zeek
event smtp_message(c: connection, header: smtp_header_rec, body: string)
```

触发时机：完整邮件消息被解析。

```zeek
# 解析邮件内容
event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    print fmt("[SMTP] Subject: %s", header$subject);
    print fmt("[SMTP] From: %s", header$from);

    for (to in header$to) {
        print fmt("[SMTP] To: %s", to);
    }

    if (header?$cc) {
        for (cc in header$cc) {
            print fmt("[SMTP] Cc: %s", cc);
        }
    }
    }
```

---

## 4. 邮件头分析

### 4.1 解析邮件头

```zeek
# 邮件头结构
type smtp_header_rec = record {
    date: string;
    from: string;
    to: vector of string;
    cc: vector of string;
    reply_to: string;
    subject: string;
    message_id: string;
    in_reply_to: string;
    references: vector of string;
    x_originating_ip: addr &optional;
};
```

### 4.2 检测伪造发件人

```zeek
# 检测 X-Originating-IP 与实际连接 IP 不匹配
event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    if (header?$x_originating_ip) {
        local orig_ip = header$x_originating_ip;
        local conn_ip = c$id$orig_h;

        if (orig_ip != conn_ip && !is_private_addr(orig_ip)) {
            NOTICE([$note = SPOOFED_EMAIL,
                    $msg = fmt("Possible email spoofing: header IP %s != connection IP %s",
                               orig_ip, conn_ip),
                    $conn = c]);
        }
    }
    }
```

### 4.3 邮件路由分析

```zeek
# 分析邮件路由路径
event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    if (c$smtp?$first_received) {
        print fmt("[SMTP] Route: %s", c$smtp$first_received);
    }
    if (c$smtp?$last_received) {
        print fmt("[SMTP] Destination: %s", c$smtp$last_received);
    }
    }
```

---

## 5. 附件分析

### 5.1 附件提取

```zeek
# 附件处理
event file_new(f: fa_file) {
    if (f$source == "SMTP") {
        print fmt("[SMTP] New attachment: %s (mime: %s)", f$id, f$mime_type);
    }
}

event file_over_new_connection(f: fa_file, c: connection, is_orig: bool) {
    if (f$source == "SMTP") {
        print fmt("[SMTP] Attachment transferred: %s (%d bytes) for %s",
                  f$id, f$size, f$name);

        if (f?$md5) {
            print fmt("[SMTP] MD5: %s", f$md5);
        }
    }
}
```

### 5.2 恶意附件检测

```zeek
# 检测恶意附件
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    if (f$source == "SMTP") {
        # 检测可执行附件
        if (/application\/x-msdownload|application\/x-executable/i in f$mime_type) {
            NOTICE([$note = MALWARE_ATTACHMENT,
                    $msg = fmt("Executable attachment: %s from %s",
                               f$name, c$id$orig_h),
                    $conn = c]);
        }

        # 检测脚本附件
        if (/application\/x-shellscript|text\/x-script/i in f$mime_type) {
            NOTICE([$note = MALICIOUS_SCRIPT,
                    $msg = fmt("Script attachment: %s", f$name),
                    $conn = c]);
        }

        # 检测文档宏
        if (/application\/vnd\.ms-|application\/vnd\.openxmlformats/i in f$mime_type) {
            print fmt("[SMTP] Office document: %s", f$name);
        }
    }
    }
```

---

## 6. 垃圾邮件检测

### 6.1 主题/发件人分析

```zeek
# 检测可疑邮件
event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    # 检测可疑主题
    local suspicious_subjects = /invoice|payment|urgent|account.*suspend|verify.*password/i;
    if (suspicious_subjects in header$subject) {
        print fmt("[SMTP] Suspicious subject: %s", header$subject);
    }

    # 检测外部邮件
    local internal_domain = "example.com";
    if (internal_domain !in header$from) {
        print fmt("[SMTP] External sender: %s", header$from);
    }
    }
```

### 6.2 邮件内容分析

```zeek
# 检测钓鱼链接
event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    # 提取 URL
    local url_pattern = /https?:\/\/[^\s<>"]+/;
    local urls = find_all_urls(body);

    for (url in urls) {
        print fmt("[SMTP] URL in email: %s", url);

        # 检测短 URL
        if (|url| < 30 && /bit\.ly|tinyurl|goo\.gl/i in url) {
            NOTICE([$note = PHISHING_URL,
                    $msg = fmt("Shortened URL in email: %s", url),
                    $conn = c]);
        }
    }
    }
```

---

## 7. SMTP 配置选项

### 7.1 主要配置项

```zeek
# SMTP 分析器配置
redef SMTP::default_port = 25/tcp;
redef SMTP::mail_smtp_ports = { 25/tcp, 587/tcp };

# 附件处理
redef SMTP::extract_all_attachments = F;
redef SMTP::only_process_messages_with_attachments = F;
redef SMTP::strict_content_transfer_encoding = F;

# 日志详细程度
redef SMTP::log_all_headers = F;
redef SMTP::log_mailhost = T;
redef SMTP::log_subject = T;

# 可执行文件过滤
redef SMTP::exe_filetypes = { "exe", "dll", "scr", "pif", "com" };
```

### 7.2 TLS/STARTTLS

```zeek
# SMTP TLS 支持
redef SMTP::starttls = T;
redef SMTP::starttls_mandatory = F;
```

---

## 8. SMTP 与文件分析联动

### 8.1 附件完整性

```zeek
# 记录附件哈希
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    if (f$source == "SMTP" && f?$md5) {
        print fmt("[SMTP] Attachment %s: MD5=%s", f$name, f$md5);

        # 可以关联威胁情报
        if (f$md5 in known_malware_md5) {
            NOTICE([$note = KNOWN_MALWARE,
                    $msg = fmt("Known malware attachment: %s", f$name),
                    $conn = c]);
        }
    }
    }
```

### 8.2 邮件内容存档

```zeek
# 完整邮件存档
event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    if (c$smtp?$subject) {
        local filename = fmt("mail_%s_%s.txt", c$uid, c$smtp$subject);
        # 这里可以写入文件或发送到存储
        print fmt("[SMTP] Archiving mail: %s", filename);
    }
    }
```

---

## 9. 实战示例

### 9.1 完整 SMTP 监控脚本

```zeek
@load base/protocols/smtp

# SMTP 监控配置
redef SMTP::extract_all_attachments = T;
redef SMTP::log_all_headers = F;

# 全局数据
global known_malware_md5: set[string] = {
    "d41d8cd98f00b204e9800998ecf8427e",
    "098f6bcd4621d373cade4e832627b4f6",
};

global suspicious_subjects = /invoice|payment|urgent|account.*suspend|verify.*password|reset.*password/i;

event smtp_message(c: connection, header: smtp_header_rec, body: string)
    {
    # 检测钓鱼主题
    if (suspicious_subjects in header$subject) {
        NOTICE([$note = PHISHING_EMAIL,
                $msg = fmt("Suspicious email subject: %s from %s",
                           header$subject, header$from),
                $conn = c]);
    }

    # 检测外部向内部发送
    local internal_domain = "mycompany.com";
    if (internal_domain in header$from && internal_domain !in header$to[0]) {
        print fmt("[SMTP] Internal to external: %s -> %s",
                  header$from, header$to);
    }

    # 检测大邮件
    if (c$smtp?$num_attachment && c$smtp$num_attachment > 5) {
        print fmt("[SMTP] Multiple attachments: %d from %s",
                  c$smtp$num_attachment, header$from);
    }
    }

event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    if (f$source == "SMTP") {
        # 检测已知恶意软件
        if (f?$md5 && f$md5 in known_malware_md5) {
            NOTICE([$note = MALWARE_ATTACHMENT,
                    $msg = fmt("Known malware: %s (MD5: %s)", f$name, f$md5),
                    $conn = c]);
        }

        # 检测可执行文件
        if (/application\/x-(msdownload|executable|shellscript)/i in f$mime_type) {
            NOTICE([$note = EXECUTABLE_ATTACHMENT,
                    $msg = fmt("Executable attachment: %s", f$name),
                    $conn = c]);
        }

        # 检测 Office 文档（可能含宏）
        if (/application\/(vnd\.ms-|vnd\.openxmlformats)/i in f$mime_type) {
            print fmt("[SMTP] Office document: %s (possible macro)", f$name);
        }
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek SMTP 分析器的核心能力：

| 组件 | 说明 |
|------|------|
| **SMTP::Info** | SMTP 日志核心 record，包含邮件头、发件人、收件人、附件 |
| **smtp_request** | SMTP 命令事件 (MAIL/RCPT/DATA) |
| **smtp_reply** | SMTP 响应事件 |
| **smtp_message** | 完整邮件消息事件 |
| **附件提取** | 集成 file_analysis 框架 |

SMTP 日志对于检测：
- 钓鱼邮件
- 恶意附件
- 垃圾邮件
- 邮件伪造
- 数据泄露（通过邮件外发）

邮件安全是网络安全的重要组成部分，SMTP 分析可以有效检测基于邮件的威胁。
