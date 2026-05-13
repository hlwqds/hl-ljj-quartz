---
title: "Zeek 深度探索 (十六)：FTP 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - ftp
  - file-transfer
  - protocol-analysis
description: "深入解析 Zeek FTP 分析器——FTP::Info record、FTP 命令/响应日志、文件传输、FTP 反弹攻击检测"
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
> 16. **第十六章：FTP 分析**

---

## 1. FTP 分析器概述

Zeek 内置 FTP 协议解析器，位于 `base/protocols/ftp` 目录。FTP 分析器可以记录 FTP 命令和响应，检测文件传输和 FTP 反弹攻击。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/ftp/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # FTP::Info 等类型定义
├── data.zeek         # FTP 数据通道处理
└── ...
```

### 1.2 FTP 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    FTP 分析器架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection (Port 21)                                   │
│       ↓                                                      │
│  FTP Command Parser (USER/PASS/RETR/STOR/CWD/etc.)          │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ftp_request     事件 (command, arg)                  │  │
│  │  ftp_reply       事件 (code, msg)                     │  │
│  │  ftp_data_request 事件 (data channel)                 │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  FTP::Info record 填充                                      │
│       ↓                                                      │
│  ftp.log + ftp-data.log 输出                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. FTP 日志格式

### 2.1 ftp.log 字段详解

```zeek
type FTP::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;          # 4-tuple

    # 用户认证
    user: string;          # FTP 用户名
    password: string;      # FTP 密码
    auth_success: bool;   # 认证是否成功

    # 命令响应
    command: string;       # FTP 命令
    arg: string;           # 命令参数
    response_code: count; # 响应码
    response_msg: string; # 响应消息

    # 文件传输
    file: string;          # 文件名
    size: count;           # 文件大小
    mode: string;          # 传输模式 (ASCII/BINARY)

    # 数据通道
    data_channel: bool;   # 是否使用数据通道

    # FTP bounce
    bounced: bool;         # 是否为 FTP 反弹攻击
    bounced_addr: addr;   # 反弹目标地址
};
```

### 2.2 ftp.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	user	auth_success	command	arg	response_code	response_msg	file	size
1672531200.123456	Cx1234abcd	192.168.1.100	52341	192.168.1.10	21	ftp_user	T	USER	ftp_user	331	Password required	-	-
1672531210.234567	Dy5678efgh	192.168.1.100	52342	192.168.1.10	21	ftp_user	T	PASS	***	230	User logged in	-	-
1672531220.345678	Dz9012ijkl	192.168.1.100	52343	192.168.1.10	21	ftp_user	T	RETR	secrets.txt	226	Transfer complete	secrets.txt	1024
```

---

## 3. FTP 脚本事件

### 3.1 ftp_request 事件

```zeek
event ftp_request(c: connection, user: string, command: string, arg: string)
```

触发时机：FTP 命令被解析。

```zeek
# 监控 FTP 命令
event ftp_request(c: connection, user: string, command: string, arg: string)
    {
    print fmt("[FTP] %s issued %s %s", user, command, arg);

    # 检测敏感命令
    if (command == "DELE" || command == "RM") {
        print fmt("[FTP] File deletion: %s", arg);
    }
    }
```

### 3.2 ftp_reply 事件

```zeek
event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool)
```

触发时机：FTP 响应被解析。

```zeek
# 监控 FTP 响应
event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool)
    {
    print fmt("[FTP] Response %d: %s", code, msg);

    # 检测传输完成
    if (code == 226) {
        print fmt("[FTP] Transfer complete");
    }

    # 检测登录失败
    if (code == 530) {
        print fmt("[FTP] Login failed: %s", msg);
    }
    }
```

---

## 4. 文件传输分析

### 4.1 RETR/STOR 命令

```zeek
# 检测文件下载
event ftp_request(c: connection, user: string, command: string, arg: string)
    {
    if (command == "RETR") {
        print fmt("[FTP] User %s downloading: %s", user, arg);

        # 检测敏感文件下载
        local sensitive = /\.passwd|\.shadow|\.kdbx|\.p12|\.pem$/i;
        if (sensitive in arg) {
            NOTICE([$note = FTP_SENSITIVE_FILE,
                    $msg = fmt("Sensitive file download via FTP: %s", arg),
                    $conn = c]);
        }
    }

    # 检测文件上传
    if (command == "STOR") {
        print fmt("[FTP] User %s uploading: %s", user, arg);

        # 检测可执行文件上传
        local dangerous = /\.(exe|dll|bat|cmd|ps1|vbs)$/i;
        if (dangerous in arg) {
            NOTICE([$note = FTP_MALWARE_UPLOAD,
                    $msg = fmt("Malicious file upload via FTP: %s", arg),
                    $conn = c]);
        }
    }
    }
```

### 4.2 文件大小分析

```zeek
# 检测大文件传输
event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool)
    {
    if (c$ftp?$size && c$ftp$size > 100 MB) {
        print fmt("[FTP] Large file transfer: %d bytes", c$ftp$size);
    }
    }
```

---

## 5. FTP 反弹攻击检测

### 5.1 PORT 命令分析

FTP 反弹攻击利用 FTP 的 PORT 命令让服务器连接其他地址。

```zeek
# FTP 反弹攻击检测
event ftp_request(c: connection, user: string, command: string, arg: string)
    {
    if (command == "PORT") {
        # 解析 PORT 命令参数 (h1,h2,h3,h4,p1,p2)
        local parts = split_string(arg, /,/);
        if (|parts| == 6) {
            local h1 = to_count(parts[0]);
            local h2 = to_count(parts[1]);
            local h3 = to_count(parts[2]);
            local h4 = to_count(parts[3]);
            local p1 = to_count(parts[4]);
            local p2 = to_count(parts[5]);

            local port = p1 * 256 + p2;
            local addr = fmt("%d.%d.%d.%d", h1, h2, h3, h4);

            # 检测非本地地址
            if (!is_private_addr(addr) && addr != c$id$resp_h) {
                NOTICE([$note = FTP_BOUNCE_ATTACK,
                        $msg = fmt("FTP bounce attempt: %s trying to connect to %s:%d",
                                   c$id$orig_h, addr, port),
                        $conn = c]);
            }

            # 记录反弹目标
            print fmt("[FTP] PORT command targets %s:%d", addr, port);
        }
    }
    }
```

### 5.2 PASV/EPSV 命令

```zeek
# 检测 PASV 响应
event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool)
    {
    if (code == 227) {
        # 解析 PASV 响应中的地址
        local match = match_pattern(msg, /227 .* \((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)/);
        if (match) {
            local h1 = to_count(match$1);
            local h2 = to_count(match$2);
            local h3 = to_count(match$3);
            local h4 = to_count(match$4);
            local p1 = to_count(match$5);
            local p2 = to_count(match$6);

            local pasv_addr = fmt("%d.%d.%d.%d", h1, h2, h3, h4);
            local pasv_port = p1 * 256 + p2;

            print fmt("[FTP] PASV response: %s:%d", pasv_addr, pasv_port);
        }
    }
    }
```

---

## 6. FTP 暴力破解检测

### 6.1 登录失败计数

```zeek
# FTP 暴力破解检测
global ftp_failures: table[addr] of count;
global ftp_last_failure: table[addr] of time;
const FTP_BRUTE_FORCE_THRESHOLD = 5;

event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool)
    {
    if (code == 530) {  # Not logged in
        local client = c$id$orig_h;
        local now = network_time();

        # 窗口清理
        if (client in ftp_last_failure && now - ftp_last_failure[client] > 10 mins) {
            ftp_failures[client] = 0;
        }

        if (client !in ftp_failures) {
            ftp_failures[client] = 0;
        }

        ftp_failures[client] += 1;
        ftp_last_failure[client] = now;

        if (ftp_failures[client] >= FTP_BRUTE_FORCE_THRESHOLD) {
            NOTICE([$note = FTP_BRUTE_FORCE,
                    $msg = fmt("FTP brute force from %s: %d failures",
                               client, ftp_failures[client]),
                    $conn = c]);
        }
    }

    # 登录成功重置计数
    if (code == 230) {  # User logged in
        local client = c$id$orig_h;
        if (client in ftp_failures) {
            ftp_failures[client] = 0;
        }
    }
    }
```

---

## 7. FTP 配置选项

### 7.1 主要配置项

```zeek
# FTP 分析器配置
redef FTP::default_port = 21/tcp;      # 默认端口
redef FTP::allow_large_files = T;       # 允许大文件
redef FTP::max_file_size = 10 GB;      # 最大文件大小

# 密码日志
redef FTP::log_password = F;            # 禁用密码记录

# 检测
redef FTP::detect_ftp_bounce = T;      # 启用 FTP 反弹检测
redef FTP::ftp_bounce_whitelist = set();  # 白名单
```

### 7.2 数据通道配置

```zeek
# FTP 数据通道
redef FTP::default_data_port = 20/tcp;
redef FTP::use_multiple_data_ports = F;
```

---

## 8. FTP 数据日志

### 8.1 ftp-data.log

FTP 数据通道（用于文件传输）单独记录。

```zeek
type FTP::DataInfo = record {
    ts: time;
    uid: string;
    id: conn_id;

    # 数据传输信息
    user: string;
    command: string;   # RETR/STOR
    arg: string;        # 文件名
    size: count;        # 传输大小
    timestamp: time;
};
```

### 8.2 数据连接监控

```zeek
# 检测 FTP 数据连接
event ftp_data_request(c: connection, user: string, command: string, arg: string)
    {
    print fmt("[FTP-DATA] %s: %s %s", user, command, arg);
    }
```

---

## 9. 实战示例

### 9.1 完整 FTP 监控脚本

```zeek
@load base/protocols/ftp

# FTP 监控配置
redef FTP::log_password = F;
redef FTP::detect_ftp_bounce = T;

# 全局状态
global ftp_failures: table[addr] of count;
global ftp_last_failure: table[addr] of time;
global ftp_transfers: table[string] of count;  # uid -> size

event ftp_reply(c: connection, code: count, msg: string, cont_resp: bool)
    {
    # 登录失败检测
    if (code == 530) {
        local client = c$id$orig_h;
        local now = network_time();

        if (client !in ftp_failures) {
            ftp_failures[client] = 0;
        }

        if (client in ftp_last_failure && now - ftp_last_failure[client] > 10 mins) {
            ftp_failures[client] = 0;
        }

        ftp_failures[client] += 1;
        ftp_last_failure[client] = now;

        if (ftp_failures[client] >= 5) {
            NOTICE([$note = FTP_BRUTE_FORCE,
                    $msg = fmt("FTP brute force from %s", client),
                    $conn = c]);
        }
    }

    # 登录成功
    if (code == 230 && c$id$orig_h in ftp_failures) {
        ftp_failures[c$id$orig_h] = 0;
    }
    }

event ftp_request(c: connection, user: string, command: string, arg: string)
    {
    # 检测文件操作
    if (command == "RETR") {
        print fmt("[FTP] Download: %s by %s", arg, user);

        # 敏感文件
        if (/\.passwd|\.shadow|\.kdbx|\.env$/i in arg) {
            NOTICE([$note = FTP_SENSITIVE_FILE,
                    $msg = fmt("Sensitive file downloaded: %s", arg),
                    $conn = c]);
        }
    }

    if (command == "STOR") {
        print fmt("[FTP] Upload: %s by %s", arg, user);

        # 可执行文件
        if (/\.(exe|dll|bat|ps1|vbs|jar)$/i in arg) {
            NOTICE([$note = FTP_MALWARE,
                    $msg = fmt("Malware uploaded: %s", arg),
                    $conn = c]);
        }
    }

    # 检测反弹攻击
    if (command == "PORT") {
        local parts = split_string(arg, /,/);
        if (|parts| == 6) {
            local addr = fmt("%s.%s.%s.%s", parts[0], parts[1], parts[2], parts[3]);
            local port = to_count(parts[4]) * 256 + to_count(parts[5]);

            if (!is_private_addr(addr) && addr != c$id$resp_h) {
                NOTICE([$note = FTP_BOUNCE_ATTACK,
                        $msg = fmt("FTP bounce attempt to %s:%d", addr, port),
                        $conn = c]);
            }
        }
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek FTP 分析器的核心能力：

| 组件             | 说明                                          |
| ---------------- | --------------------------------------------- |
| **FTP::Info**    | FTP 日志核心 record，包含命令、响应、用户信息 |
| **ftp_request**  | FTP 命令事件 (USER/PASS/RETR/STOR/PORT 等)    |
| **ftp_reply**    | FTP 响应事件 (230/530 等)                     |
| **ftp-data.log** | FTP 数据通道日志                              |
| **反弹攻击检测** | 检测 PORT 命令指向外部地址                    |

FTP 日志对于检测：

- FTP 暴力破解
- 敏感文件访问
- 恶意文件上传
- FTP 反弹攻击
- 文件传输审计

FTP 协议虽然老旧，但在许多环境中仍在使用，监控 FTP 流量仍然重要。
