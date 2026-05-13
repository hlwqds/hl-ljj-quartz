---
title: "Zeek 深度探索 (十五)：SSH 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - ssh
  - remote-access
  - brute-force
  - protocol-analysis
description: "深入解析 Zeek SSH 分析器——SSH::Info record、认证日志、客户端/服务器指纹、暴力破解检测、SSH 隧道"
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
> 15. **第十五章：SSH 分析**

---

## 1. SSH 分析器概述

Zeek 内置 SSH 协议解析器，位于 `base/protocols/ssh` 目录。SSH 分析器可以检测暴力破解、识别客户端/服务器指纹、发现 SSH 隧道。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/ssh/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # SSH::Info 等类型定义
└── ...
```

### 1.2 SSH 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SSH 分析器架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection (Port 22)                                    │
│       ↓                                                      │
│  SSH Key Exchange (KEX)                                      │
│  ├── SSH Client/Server Version                              │
│  ├── Key Exchange Init (ciphers, hashes, key algos)         │
│  └── NewKeys (symmetric key)                                │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ssh_server_version  事件                            │  │
│  │  ssh_auth_successful   事件                          │  │
│  │  ssh_auth_failed       事件                          │  │
│  │  ssh_auth_attempted    事件                          │  │
│  │  ssh隧道               事件                          │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  SSH::Info record 填充                                      │
│       ↓                                                      │
│  ssh.log 输出                                                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. SSH 日志格式

### 2.1 ssh.log 字段详解

```zeek
type SSH::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;          # 4-tuple

    # 连接状态
    version: string;       # SSH 协议版本 (SSH-2.0, SSH-1.99)
    software: string;      # 软件标识

    # 认证
    auth_success: bool;   # 认证是否成功
    auth_method: string;  # 认证方法 (password/publickey/keyboard-interactive)
    authAttempts: count;  # 认证尝试次数
    user: string;         # 用户名

    # 客户端指纹
    client: string;       # 客户端软件字符串
    c_key_type: string;   # 客户端密钥类型
    c_key: string;        # 客户端公钥

    # 服务器指纹
    server: string;        # 服务器软件字符串
    s_key_type: string;   # 服务器密钥类型
    s_key: string;        # 服务器公钥

    # 加密
    cipher: string;       # 加密算法
    mac: string;          # MAC 算法
    compression: string;  # 压缩算法

    # 隧道
    tunnel_local_addrs: addr;    # 隧道本地地址
    tunnel_remote_addrs: addr;   # 隧道远程地址
    tunnel_established: bool;    # 隧道是否建立

    # 异常
    rejected_versions: vector of string;  # 被拒绝的版本
    reasons: vector of string;           # 拒绝原因
};
```

### 2.2 ssh.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	version	auth_success	auth_method	authAttempts	user	client	cipher	mac
1672531200.123456	Cx1234abcd	192.168.1.100	52341	192.168.1.10	22	SSH-2.0-OpenSSH_8.9p1	T	password	1	admin	SSH::CHACHA20_POLY1305	SSH::HMAC_SHA256_ETM
1672531220.234567	Dy5678efgh	192.168.1.100	52342	192.168.1.10	22	SSH-2.0-OpenSSH_8.9p1	F	publickey	3	root	SSH::AES256_CTR	SSH::HMAC_SHA1
```

---

## 3. SSH 脚本事件

### 3.1 ssh_server_version 事件

```zeek
event ssh_server_version(c: connection, version: string)
```

触发时机：SSH 服务器版本字符串被解析。

```zeek
# 识别 SSH 服务器类型
event ssh_server_version(c: connection, version: string)
    {
    print fmt("[SSH] Server %s: %s", c$id$resp_h, version);

    # 检测 OpenSSH 版本
    if (/OpenSSH/i in version) {
        local match = match_pattern(version, /OpenSSH_([0-9.]+)/);
        if (match) {
            print fmt("[SSH] OpenSSH version: %s", match$str);
        }
    }
    }
```

### 3.2 ssh_auth_successful 事件

```zeek
event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
```

触发时机：SSH 认证成功。

```zeek
# 监控 SSH 登录
event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
    {
    print fmt("[SSH] Login success: %s@%s (method: %s)",
              used_user, c$id$orig_h, auth_method);

    # 检测 root 登录
    if (used_user == "root") {
        NOTICE([$note = ROOT_LOGIN,
                $msg = fmt("Root login via SSH from %s", c$id$orig_h),
                $conn = c]);
    }
    }
```

### 3.3 ssh_auth_failed 事件

```zeek
event ssh_auth_failed(c: connection, auth_method_none: bool,
                     auth_method: string, used_user: string,
                     remote_location:geo detail)
```

触发时机：SSH 认证失败。

```zeek
# 监控 SSH 认证失败
event ssh_auth_failed(c: connection, auth_method_none: bool,
                     auth_method: string, used_user: string)
    {
    print fmt("[SSH] Login failed: %s@%s (method: %s)",
              used_user, c$id$orig_h, auth_method);
    }
```

---

## 4. 暴力破解检测

### 4.1 暴力破解计数器

```zeek
# SSH 暴力破解检测
global ssh_failed_logins: table[addr] of count;
global ssh_last_attempt: table[addr] of time;
const SSH_BRUTE_FORCE_THRESHOLD = 5;
const SSH_BRUTE_FORCE_WINDOW = 5 mins;

event ssh_auth_failed(c: connection, auth_method_none: bool,
                     auth_method: string, used_user: string)
    {
    local client = c$id$orig_h;
    local now = network_time();

    # 初始化
    if (client !in ssh_failed_logins) {
        ssh_failed_logins[client] = 0;
    }

    # 检查时间窗口
    if (client in ssh_last_attempt) {
        if (now - ssh_last_attempt[client] > SSH_BRUTE_FORCE_WINDOW) {
            ssh_failed_logins[client] = 0;
        }
    }

    ssh_failed_logins[client] += 1;
    ssh_last_attempt[client] = now;

    # 检测暴力破解
    if (ssh_failed_logins[client] >= SSH_BRUTE_FORCE_THRESHOLD) {
        NOTICE([$note = SSH_BRUTE_FORCE,
                $msg = fmt("SSH brute force detected: %s made %d failed attempts",
                           client, ssh_failed_logins[client]),
                $conn = c]);
    }
    }
```

### 4.2 凭证填充检测

```zeek
# 检测同一用户从不同 IP 登录
global ssh_user_ips: table[string] of set[addr];

event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
    {
    local client = c$id$orig_h;

    if (used_user !in ssh_user_ips) {
        ssh_user_ips[used_user] = set();
    }

    # 检测同一用户从多个 IP 登录
    if (|ssh_user_ips[used_user]| > 3) {
        NOTICE([$note = CREDENTIAL_STUFFING,
                $msg = fmt("Possible credential stuffing: %s logged in from %d different IPs",
                           used_user, |ssh_user_ips[used_user]|),
                $conn = c]);
    }

    add ssh_user_ips[used_user][client];
    }
```

---

## 5. SSH 指纹分析

### 5.1 SSH 客户端指纹

```zeek
# 客户端软件指纹
event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
    {
    if (c$ssh?$client) {
        print fmt("[SSH] Client: %s", c$ssh$client);

        # 检测攻击工具
        if (/hydra|medusa|ncrack|masscan/i in c$ssh$client) {
            NOTICE([$note = SSH_ATTACK_TOOL,
                    $msg = fmt("SSH attack tool detected: %s from %s",
                               c$ssh$client, c$id$orig_h),
                    $conn = c]);
        }
    }

    # 检测密钥类型
    if (c$ssh?$c_key_type) {
        print fmt("[SSH] Client key type: %s", c$ssh$c_key_type);
    }
    }
```

### 5.2 软件版本异常检测

```zeek
# 检测异常 SSH 版本字符串
event ssh_server_version(c: connection, version: string)
    {
    # 正常的 SSH 版本格式
    local valid_ssh_version = /SSH-[0-9]\.[0-9]-.*/;

    if (version !in valid_ssh_version) {
        NOTICE([$note = WEIRD_SSH_VERSION,
                $msg = fmt("Invalid SSH version string: %s from %s",
                           version, c$id$resp_h),
                $conn = c]);
    }
    }
```

---

## 6. SSH 隧道检测

### 6.1 本地端口转发检测

SSH 隧道可以通过 `-L` 参数建立本地端口转发。

```zeek
# SSH 隧道检测
event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
    {
    if (c$ssh?$tunnel_established && c$ssh$tunnel_established) {
        print fmt("[SSH] SSH tunnel established by %s@%s", used_user, c$id$orig_h);

        if (c$ssh?$tunnel_local_addrs) {
            print fmt("[SSH] Tunnel local: %s", c$ssh$tunnel_local_addrs);
        }

        if (c$ssh?$tunnel_remote_addrs) {
            print fmt("[SSH] Tunnel remote: %s", c$ssh$tunnel_remote_addrs);
        }
    }
    }
```

### 6.2 动态端口转发检测

动态端口转发（-D）创建 SOCKS 代理。

```zeek
# 检测 SOCKS 代理使用
event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
    {
    # SSH 动态转发特征
    if (c$ssh?$tunnel_local_addrs && c$ssh?$tunnel_remote_addrs) {
        NOTICE([$note = SSH_TUNNEL,
                $msg = fmt("SSH dynamic port forwarding by %s@%s",
                           used_user, c$id$orig_h),
                $conn = c]);
    }
    }
```

---

## 7. SSH 配置选项

### 7.1 主要配置项

```zeek
# SSH 分析器配置
redef SSH::disable_password_logging = T;  # 禁用密码日志
redef SSH::disable_extra_packets = F;      # 记录额外数据包
redef SSH::max_auth_attempts = 100;       # 最大认证尝试次数
redef SSH::banner_timeout = 30 secs;       # 版本协商超时

# 暴力破解检测
redef SSH::brute_force_login_threshold = 5;
redef SSH::brute_force_password_threshold = 5;
redef SSH::brute_force_publickey_threshold = 5;

# 隧道检测
redef SSH::tunnel_detection = T;
```

### 7.2 指纹提取

```zeek
# 提取 SSH 指纹
redef SSH::extract_client_host_key = T;
redef SSH::extract_server_host_key = T;
```

---

## 8. 实战示例

### 8.1 完整 SSH 监控脚本

```zeek
@load base/protocols/ssh

# SSH 监控配置
redef SSH::disable_password_logging = T;

# 全局状态
global ssh_failures: table[addr] of count;
global ssh_last_failure: table[addr] of time;
global suspicious_users = { "root", "admin", "ubuntu", "centos" };

event ssh_auth_failed(c: connection, auth_method_none: bool,
                     auth_method: string, used_user: string)
    {
    local client = c$id$orig_h;
    local now = network_time();

    # 窗口清理
    if (client in ssh_last_failure && now - ssh_last_failure[client] > 10 mins) {
        ssh_failures[client] = 0;
    }

    if (client !in ssh_failures) {
        ssh_failures[client] = 0;
    }

    ssh_failures[client] += 1;
    ssh_last_failure[client] = now;

    # 检测暴力破解
    if (ssh_failures[client] >= 5) {
        NOTICE([$note = SSH_BRUTE_FORCE,
                $msg = fmt("SSH brute force from %s: %d failures",
                           client, ssh_failures[client]),
                $conn = c]);
    }

    # 检测可疑用户名
    if (used_user in suspicious_users) {
        print fmt("[SSH] Failed login attempt for %s from %s",
                  used_user, client);
    }
    }

event ssh_auth_successful(c: connection, auth_method_none: bool,
                          auth_method: string, used_user: string)
    {
    # 重置失败计数
    local client = c$id$orig_h;
    if (client in ssh_failures) {
        ssh_failures[client] = 0;
    }

    # 检测 root 登录
    if (used_user == "root") {
        NOTICE([$note = ROOT_SSH_LOGIN,
                $msg = fmt("Root SSH login from %s", client),
                $conn = c]);
    }

    # 检测异常登录时间
    local t = current_time();
    local hour = to_portfolio_hour(t);
    if (hour >= 22 || hour <= 5) {
        print fmt("[SSH] Off-hours login: %s at %s", used_user, t);
    }

    # 检测 SSH 隧道
    if (c$ssh?$tunnel_established && c$ssh$tunnel_established) {
        NOTICE([$note = SSH_TUNNEL,
                $msg = fmt("SSH tunnel established by %s from %s",
                           used_user, client),
                $conn = c]);
    }
    }

event ssh_server_version(c: connection, version: string)
    {
    # 检测服务器软件
    if (/OpenSSH/i in version) {
        print fmt("[SSH] OpenSSH server: %s", version);
    } else if (/Dropbear/i in version) {
        print fmt("[SSH] Dropbear server: %s", version);
    } else if (/PuTTY/i in version) {
        print fmt("[SSH] PuTTY server: %s", version);
    }
    }
```

---

## 9. 小结

本章介绍了 Zeek SSH 分析器的核心能力：

| 组件 | 说明 |
|------|------|
| **SSH::Info** | SSH 日志核心 record，包含认证、指纹、隧道信息 |
| **ssh_auth_successful** | 认证成功事件 |
| **ssh_auth_failed** | 认证失败事件 |
| **ssh_server_version** | 服务器版本事件 |
| **暴力破解检测** | 基于失败次数的检测 |
| **SSH 隧道检测** | 检测端口转发隧道 |

SSH 日志对于检测：
- SSH 暴力破解
- 异常登录（root/非工作时段）
- SSH 攻击工具
- 凭证填充攻击
- SSH 隧道隐蔽通信

至关重要，是网络安全监控的核心协议之一。
