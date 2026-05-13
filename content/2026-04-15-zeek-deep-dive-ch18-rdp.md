---
title: "Zeek 深度探索 (十八)：RDP 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - rdp
  - remote-desktop
  - protocol-analysis
description: "深入解析 Zeek RDP 分析器——RDP::Info record、RDP 连接日志、加密级别、屏幕截图提取"
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
> 18. **第十八章：RDP 分析**

---

## 1. RDP 分析器概述

Zeek 内置 RDP（Remote Desktop Protocol）协议解析器，位于 `base/protocols/rdp` 目录。RDP 是 Windows 远程桌面协议，常用于横向移动。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/rdp/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # RDP::Info 等类型定义
└── ...
```

### 1.2 RDP 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    RDP 分析器架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection (Port 3389)                                  │
│       ↓                                                      │
│  RDP Connection Sequence                                      │
│  ├── X.224 Connection Request                               │
│  ├── T.123 Data Packets                                     │
│  └── T.125 MCS Connect-Initial                              │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  rdp_connect_request  事件                            │  │
│  │  rdp_connect_response 事件                            │  │
│  │  rdp_disconnect       事件                           │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  RDP::Info record 填充                                       │
│       ↓                                                      │
│  rdp.log 输出                                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. RDP 日志格式

### 2.1 rdp.log 字段详解

```zeek
type RDP::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;          # 4-tuple

    # 连接信息
    cookie: string;       # RDP cookie (用户名)
    result: string;        # 连接结果
    security_protocol: string;  # 安全协议 (RDP/TLS/CredSSP)
    security_protocol_reason: string;  # 拒绝原因

    # 客户端信息
    client: string;       # 客户端信息
    client_build: string;  # 客户端版本

    # 加密
    encryption_level: string;  # 加密级别 (None/Low/ClientCompatible/High)
    encryption_method: string; # 加密方法

    # 证书
    cert_type: count;      # 证书类型
    cert_count: count;    # 证书数量
    cert_permanent: bool;  # 证书是否永久
    encryption_method: count;  # 加密方法
    server_random: string; # 服务器随机数

    # GUI
    desk_width: count;    # 桌面宽度
    desk_height: count;   # 桌面高度
    use_resolution: bool; # 使用分辨率
    requested_color_depth: count;  # 请求的颜色深度
    actual_color_depth: count;     # 实际颜色深度

    # 键盘
    keyboard_layout: count;  # 键盘布局
    keyboard_type: count;   # 键盘类型
    keyboard_subtype: count;# 键盘子类型
    keyboard_function_key: count; # 功能键

    # 杂项
    ime_file_name: string;  # IME 文件名
    connection_duration: interval;  # 连接时长
    disconnect_duration: interval;  # 断开时长
};
```

### 2.2 rdp.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	cookie	result	security_protocol	security_protocol_reason	client_build	desk_width	desk_height	encryption_level	encryption_method
1672531200.123456	Cx1234abcd	192.168.1.100	52341	192.168.1.10	3389	administrator	Success	TLS	-	10.0.17134	1920	1080	High	56
```

---

## 3. RDP 脚本事件

### 3.1 rdp_connect_request 事件

```zeek
event rdp_connect_request(c: connection, cookie: string)
```

触发时机：RDP 连接请求（cookie 通常是用户名）。

```zeek
# 监控 RDP 连接请求
event rdp_connect_request(c: connection, cookie: string)
    {
    print fmt("[RDP] Connection request: user=%s from %s",
              cookie, c$id$orig_h);
    }
```

### 3.2 rdp_connect_response 事件

```zeek
event rdp_connect_response(c: connection, result: string,
                          security_protocol: string, security_protocol_reason: string)
```

触发时机：RDP 连接响应。

```zeek
# 监控 RDP 连接响应
event rdp_connect_response(c: connection, result: string,
                          security_protocol: string, security_protocol_reason: string)
    {
    print fmt("[RDP] Connection response: %s (protocol: %s)", result, security_protocol);

    if (result != "Success") {
        print fmt("[RDP] Connection failed: %s - %s", result, security_protocol_reason);
    }
    }
```

---

## 4. RDP 连接分析

### 4.1 连接追踪

```zeek
# 追踪 RDP 连接
global rdp_connections: table[string] of RDP::Info;  # uid -> info

event rdp_connect_request(c: connection, cookie: string)
    {
    print fmt("[RDP] New RDP connection: %s -> %s (user: %s)",
              c$id$orig_h, c$id$resp_h, cookie);

    rdp_connections[c$uid] = c$rdp;
    }

event rdp_connect_response(c: connection, result: string,
                          security_protocol: string, security_protocol_reason: string)
    {
    if (result == "Success") {
        print fmt("[RDP] Successful RDP session established");
    } else {
        print fmt("[RDP] RDP failed: %s", result);
    }
    }
```

### 4.2 客户端指纹

```zeek
# 识别 RDP 客户端
event rdp_connect_request(c: connection, cookie: string)
    {
    if (c$rdp?$client_build) {
        print fmt("[RDP] Client build: %s", c$rdp$client_build);

        # 检测过时客户端
        if (c$rdp$client_build < "10.0.17763") {
            NOTICE([$note = OLD_RDP_CLIENT,
                    $msg = fmt("Outdated RDP client: %s from %s",
                               c$rdp$client_build, c$id$orig_h),
                    $conn = c]);
        }
    }
    }
```

---

## 5. 加密级别分析

### 5.1 检测弱加密

```zeek
# 检测 RDP 加密级别
event rdp_connect_response(c: connection, result: string,
                          security_protocol: string, security_protocol_reason: string)
    {
    if (c$rdp?$encryption_level) {
        local level = c$rdp$encryption_level;
        print fmt("[RDP] Encryption level: %s", level);

        # 检测无加密或弱加密
        if (level == "None" || level == "Low") {
            NOTICE([$note = WEAK_RDP_ENCRYPTION,
                    $msg = fmt("Weak/no encryption RDP from %s: %s",
                               c$id$orig_h, level),
                    $conn = c]);
        }
    }
    }
```

### 5.2 检测 NLA

```zeek
# 检测网络级身份验证 (NLA)
event rdp_connect_response(c: connection, result: string,
                          security_protocol: string, security_protocol_reason: string)
    {
    if (c$rdp?$security_protocol) {
        if (c$rdp$security_protocol == "CredSSP") {
            print fmt("[RDP] NLA required for %s", c$id$resp_h);
        } else if (c$rdp$security_protocol == "RDP") {
            NOTICE([$note = NO_NLA,
                    $msg = fmt("RDP without NLA: %s", c$id$resp_h),
                    $conn = c]);
        }
    }
    }
```

---

## 6. 恶意 RDP 检测

### 6.1 异常连接检测

```zeek
# 检测异常 RDP 活动
global rdp_connection_count: table[addr] of count;
global rdp_target_count: table[addr] of set[addr];

event rdp_connect_request(c: connection, cookie: string)
    {
    local client = c$id$orig_h;
    local server = c$id$resp_h;

    # 统计单个客户端的 RDP 连接
    if (client !in rdp_connection_count) {
        rdp_connection_count[client] = 0;
    }
    rdp_connection_count[client] += 1;

    # 统计连接的目标
    if (client !in rdp_target_count) {
        rdp_target_count[client] = set();
    }
    add rdp_target_count[client][server];

    # 检测横向移动特征
    if (rdp_connection_count[client] > 10) {
        NOTICE([$note = RDP_HORIZONTAL_MOVEMENT,
                $msg = fmt("Possible lateral movement: %s made %d RDP connections",
                           client, rdp_connection_count[client]),
                $conn = c]);
    }

    # 检测连接多个不同目标
    if (|rdp_target_count[client]| > 5) {
        print fmt("[RDP] %s connecting to %d different servers", client, |rdp_target_count[client]|);
    }
    }
```

### 6.2 敏感时段 RDP

```zeek
# 检测非工作时段 RDP
event rdp_connect_request(c: connection, cookie: string)
    {
    local t = current_time();
    local hour = to_portfolio_hour(t);

    # 检测下班时间连接
    if (hour >= 22 || hour <= 5) {
        NOTICE([$note = RDP_OFF_HOURS,
                $msg = fmt("Off-hours RDP: %s connecting to %s",
                           c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }
    }
```

---

## 7. RDP 配置选项

### 7.1 主要配置项

```zeek
# RDP 分析器配置
redef RDP::default_port = 3389/tcp;
redef RDP::disable_cert_log = F;         # 禁用证书日志
redef RDP::disable_geoip = F;             # 禁用 GeoIP

# 证书验证
redef RDP::validate_cert = F;
redef RDP::check_cert_expiry = T;
```

### 7.2 日志配置

```zeek
# 详细日志
redef RDP::log_rdp_cookie = T;
redef RDP::log_all_connection_info = T;
```

---

## 8. RDP 与屏幕截图

### 8.1 屏幕截图检测

RDP 本身不传输完整截图，但可以通过文件分析框架检测 RDP 会话中复制的文件。

```zeek
# 检测通过 RDP 复制的文件
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    # RDP 文件传输特征
    # 注意：RDP 本身不直接传输文件，这里用于检测相关活动
    if (c$rdp?$uid) {
        print fmt("[RDP] File activity during RDP session: %s", f$name);
    }
    }
```

---

## 9. 实战示例

### 9.1 完整 RDP 监控脚本

```zeek
@load base/protocols/rdp

# RDP 监控配置
redef RDP::log_rdp_cookie = T;

# 全局状态
global rdp_failures: table[addr] of count;
global rdp_success: table[addr] of count;

event rdp_connect_request(c: connection, cookie: string)
    {
    print fmt("[RDP] Connection request: %s -> %s (user: %s)",
              c$id$orig_h, c$id$resp_h, cookie);

    # 检测 admin 账户
    if (cookie == "Administrator" || cookie == "administrator") {
        print fmt("[RDP] Administrator RDP attempt from %s", c$id$orig_h);
    }
    }

event rdp_connect_response(c: connection, result: string,
                          security_protocol: string, security_protocol_reason: string)
    {
    local client = c$id$orig_h;
    local server = c$id$resp_h;

    if (result == "Success") {
        if (client !in rdp_success) {
            rdp_success[client] = 0;
        }
        rdp_success[client] += 1;

        print fmt("[RDP] Successful RDP: %s -> %s", client, server);

        # 检测 NLA
        if (security_protocol != "CredSSP") {
            NOTICE([$note = RDP_NO_NLA,
                    $msg = fmt("RDP without NLA: %s -> %s", client, server),
                    $conn = c]);
        }

        # 检测加密级别
        if (c$rdp?$encryption_level && c$rdp$encryption_level == "None") {
            NOTICE([$note = RDP_NO_ENCRYPTION,
                    $msg = fmt("Unencrypted RDP: %s -> %s", client, server),
                    $conn = c]);
        }
    } else {
        if (client !in rdp_failures) {
            rdp_failures[client] = 0;
        }
        rdp_failures[client] += 1;

        print fmt("[RDP] Failed RDP: %s -> %s: %s",
                  client, server, result);

        if (rdp_failures[client] > 5) {
            NOTICE([$note = RDP_BRUTE_FORCE,
                    $msg = fmt("RDP brute force from %s: %d failures",
                               client, rdp_failures[client]),
                    $conn = c]);
        }
    }
    }

event rdp_connect_request(c: connection, cookie: string)
    {
    # 非工作时段检测
    local t = current_time();
    local hour = to_portfolio_hour(t);

    if (hour >= 22 || hour <= 5) {
        NOTICE([$note = RDP_OFF_HOURS,
                $msg = fmt("Off-hours RDP: %s -> %s (user: %s)",
                           c$id$orig_h, c$id$resp_h, cookie),
                $conn = c]);
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek RDP 分析器的核心能力：

| 组件                     | 说明                                                    |
| ------------------------ | ------------------------------------------------------- |
| **RDP::Info**            | RDP 日志核心 record，包含连接信息、加密级别、客户端信息 |
| **rdp_connect_request**  | RDP 连接请求事件，包含用户名 cookie                     |
| **rdp_connect_response** | RDP 连接响应事件，包含结果和协议信息                    |
| **加密级别**             | 检测 None/Low/High 加密                                 |
| **NLA 检测**             | 检测是否使用网络级身份验证                              |

RDP 日志对于检测：

- RDP 暴力破解
- 横向移动
- 异常时段连接
- 弱加密 RDP
- 无 NLA 的 RDP 连接

RDP 是 Windows 环境中的重要横向移动向量，RDP 监控对于检测攻击至关重要。
