---
title: "Zeek 深度探索 (十四)：SMB 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - smb
  - cifs
  - samba
  - file-transfer
  - protocol-analysis
description: "深入解析 Zeek SMB 分析器——SMB::Info record、SMB2 协议、文件传输日志、命名管道、NTLM 认证"
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
> 14. **第十四章：SMB 分析**

---

## 1. SMB 分析器概述

Zeek 内置 SMB/CIFS 协议解析器（SMB1 和 SMB2），位于 `base/protocols/smb` 目录。SMB 是 Windows 环境中最核心的文件共享协议。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/smb/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # SMB::Info 等类型定义
├── smb1.zeek          # SMB1 分析器
├── smb2.zeek          # SMB2 分析器
├── files.zeek         # SMB 文件传输
└── ...
```

### 1.2 SMB 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    SMB 分析器架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection (Port 445)                                   │
│       ↓                                                      │
│  SMB Dialect Detection (SMB1/SMB2/SMB3)                     │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  smb_connect    事件 (tree connect)                   │  │
│  │  smb_disconnect 事件 (tree disconnect)                  │  │
│  │  smb_request    事件 (SMB command)                      │  │
│  │  smb_reply      事件 (SMB response)                    │  │
│  │  smb_file_open  事件 (file open)                       │  │
│  │  smb_file_close 事件 (file close)                      │  │
│  │  smb_write      事件 (write to file)                    │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  SMB::Info record + smb_files.log                           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. SMB 日志格式

### 2.1 smb.log 字段详解

```zeek
type SMB::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;          # 4-tuple

    # SMB 会话
    primary_session_id: string;  # 主会话 ID
    session_id: string;          # 当前会话 ID

    # 命令信息
    command: string;       # SMB 命令 (TREE_CONNECT, CREATE, etc.)
    sub_command: string;  # 子命令 (SMB2 CREATE, etc.)
    status: string;        # SMB 状态码
    status_code: count;    # 数字状态码

    # 树连接
    tree_id: string;       # 树 ID
    share_type: string;    # Share 类型 (DISK/PIPE/PRINTER)
    share_name: string;    # 共享名称

    # 文件信息
    referenced_file_name: string;   # 引用的文件名
    file_name: string;              # 文件名
    fid: string;                    # 文件 ID
    action: string;                 # 操作 (OPENED/MODIFIED/etc.)

    # 认证
    user: string;          # 用户名
    client_hashes: string; # 客户端发送的哈希
    server_hashes: string; # 服务端发送的哈希

    # NTLM
    ntlm_success: bool;    # NTLM 认证成功

    # 加密
    encrypted: bool;       # 是否加密（SMB3）
    encryption_algorithm: string;  # 加密算法
};
```

### 2.2 smb_files.log 字段

```zeek
type SMB::FileInfo = record {
    ts: time;
    uid: string;
    id: conn_id;

    # 文件标识
    fuid: string;          # 文件唯一 ID
    action: string;       # 文件操作 (CREATED/OPENED/CLOSED/etc.)

    # 路径信息
    path: string;          # 文件路径
    name: string;          # 文件名
    size: count;           # 文件大小

    # 时间戳
    times: SMB::FileTimes;  # 创建/访问/修改时间

    # 哈希
    md5: string &optional;
    sha1: string &optional;
    sha256: string &optional;

    # SMB 特定
    last_write: time;      # 最后写入时间
};
```

### 2.3 日志示例

```
# smb.log
ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	command	sub_command	status	tree_id	share_name	referenced_file_name	file_name	fid	action	user
1672531200.123	Cx1234abcd	192.168.1.100	445	192.168.1.10	445	SMB::TREE_CONNECT	SMB2::TREE_CONNECT	SUCCESS	0x1234	IPC$	-	-	-	-	WORKGROUP\user

# smb_files.log
ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	fuid	action	path	name	size	md5
1672531210.456	Dy5678efgh	192.168.1.100	445	192.168.1.10	445	Fy12345678	OPENED	\\share\docs	report.docx	45231	d41d8cd98f00b204e9800998ecf8427e
```

---

## 3. SMB 脚本事件

### 3.1 smb_connect 事件

```zeek
event smb_connect(c: connection, hdr: SMB::Header, path: string,
                  share_type: string, share_flags: count)
```

触发时机：SMB 树连接（TREE_CONNECT）请求。

```zeek
# 监控 SMB 共享访问
event smb_connect(c: connection, hdr: SMB::Header, path: string,
                  share_type: string, share_flags: count)
    {
    print fmt("[SMB] Tree Connect: %s -> %s (type: %s)",
              c$id$orig_h, path, share_type);

    # 检测 IPC$ 连接（常用于横向移动）
    if (path == "IPC$") {
        print fmt("[SMB] IPC$ connection from %s", c$id$orig_h);
    }
    }
```

### 3.2 smb_file_open 事件

```zeek
event smb_file_open(c: connection, hdr: SMB::Header, fid: string,
                    name: string, path: string)
```

触发时机：文件被打开时。

```zeek
# 检测敏感文件访问
event smb_file_open(c: connection, hdr: SMB::Header, fid: string,
                    name: string, path: string)
    {
    local sensitive_files = /\.passwd|\.shadow|\.kdbx|\.p12|\.pfx$/i;

    if (sensitive_files in name) {
        NOTICE([$note = SMB_SENSITIVE_FILE,
                $msg = fmt("Sensitive file accessed via SMB: %s by %s",
                           name, c$id$orig_h),
                $conn = c]);
    }

    print fmt("[SMB] File opened: %s on %s", name, c$id$resp_h);
    }
```

### 3.3 smb_write 事件

```zeek
event smb_write(c: connection, hdr: SMB::Header, fid: string,
                offset: count, size: count, data: string)
```

触发时机：数据写入文件时。

```zeek
# 监控 SMB 写入
event smb_write(c: connection, hdr: SMB::Header, fid: string,
                offset: count, size: count, data: string)
    {
    print fmt("[SMB] Write to FID %s: %d bytes at offset %d",
              fid, size, offset);
    }
```

### 3.4 smb_close 事件

```zeek
event smb_close(c: connection, hdr: SMB::Header, fid: string,
                duration: interval)
```

触发时机：文件关闭时。

---

## 4. SMB 文件传输分析

### 4.1 文件提取

```zeek
# 启用 SMB 文件提取
event file_new(f: fa_file) {
    if (f$source == "SMB") {
        print fmt("[SMB] New file: %s (size: %s)", f$id, f$size);
    }
}

# SMB 文件完成
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool) {
    if (f$source == "SMB") {
        print fmt("[SMB] File transferred: %s (%s bytes)", f$id, f$size);
    }
}
```

### 4.2 恶意文件检测

```zeek
# 检测可执行文件传输
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool) {
    if (f$source == "SMB" && f?$mime_type) {
        if (/application\/x-msdownload|application\/x-executable/i in f$mime_type) {
            NOTICE([$note = MALWARE_FILE,
                    $msg = fmt("Executable transferred via SMB: %s from %s",
                               f$name, c$id$orig_h),
                    $conn = c]);
        }

        # 检测脚本文件
        if (/application\/x-shellscript|text\/x-script/i in f$mime_type) {
            NOTICE([$note = SUSPICIOUS_SCRIPT,
                    $msg = fmt("Script transferred via SMB: %s", f$name),
                    $conn = c]);
        }
    }
}
```

---

## 5. 横向移动检测

### 5.1 PSEXEC 检测

PSEXEC 是常见的横向移动工具，通过 SMB 执行远程命令。

```zeek
# 检测 PSEXEC 特征
event smb_connect(c: connection, hdr: SMB::Header, path: string,
                  share_type: string, share_flags: count)
    {
    # PSEXEC 使用 ADMIN$ 共享
    if (/ADMIN\$|C\$|PRINT\$/ in path && c$smb?$user) {
        print fmt("[SMB] Admin share access: %s by %s", path, c$smb$user);
    }
    }

# 检测 PSEXEC 服务创建
event smb_request(c: connection, hdr: SMB::Header,
                  command: SMB::Command, sub_command: string)
    {
    # SMB2 CREATE 请求打开服务可执行文件路径
    if (command == SMB2::CREATE && /psexesvc/i in sub_command) {
        NOTICE([$note = PSEXEC_DETECTED,
                $msg = fmt("Possible PSEXEC from %s", c$id$orig_h),
                $conn = c]);
    }
    }
```

### 5.2 WMI 检测

WMI（Windows Management Instrumentation）远程执行也常通过 SMB 135/445 端口。

```zeek
# 检测 WMI 命名管道访问
event smb_connect(c: connection, hdr: SMB::Header, path: string,
                  share_type: string, share_flags: count)
    {
    if (share_type == "PIPE" && /WMI/i in path) {
        NOTICE([$note = WMI_USAGE,
                $msg = fmt("WMI access from %s", c$id$orig_h),
                $conn = c]);
    }
    }
```

### 5.3 SMB 枚举检测

```zeek
# 检测 SMB 共享枚举
event smb_request(c: connection, hdr: SMB::Header,
                  command: SMB::Command, sub_command: string)
    {
    if (command == SMB2::QUERY_DIRECTORY) {
        print fmt("[SMB] Directory enumeration: %s", c$id$orig_h);
    }
    }
```

---

## 6. SMB 配置选项

### 6.1 主要配置项

```zeek
# SMB 分析器配置
redef SMB::disable_cert_log = F;      # 禁用证书日志
redef SMB::disable_password_logging = T;  # 禁用密码日志
redef SMB::log_file_all = F;           # 记录所有文件操作

# 文件提取
redef SMB::extract_all_files = F;      # 提取所有文件
redef SMB::extract_xlsx = T;           # 提取 Excel
redef SMB::extract_docx = T;           # 提取 Word
redef SMB::extract_pdf = T;            # 提取 PDF

# 哈希计算
redef FileExtract::default_md5 = T;    # 计算 MD5
redef FileExtract::compute_sha = T;    # 计算 SHA
```

### 6.2 SMB 端口配置

```zeek
# 默认端口
redef SMB::default_port = 445/tcp;

# 添加其他端口
redef SMB::default_ports = { 139/tcp, 445/tcp };
```

---

## 7. NTLM 认证分析

### 7.1 NTLM 哈希

```zeek
# 检测 NTLM 认证
event smb_request(c: connection, hdr: SMB::Header,
                  command: SMB::Command, sub_command: string)
    {
    if (c$smb?$client_hashes && c$smb$client_hashes != "-") {
        print fmt("[SMB] NTLM client hash: %s from %s",
                  c$smb$client_hashes, c$id$orig_h);
    }
    }
```

### 7.2 弱密码检测

```zeek
# 检测 NTLM 认证失败
event smb_request(c: connection, hdr: SMB::Header,
                  command: SMB::Command, sub_command: string)
    {
    if (c$smb?$status && /NT_STATUS/i in c$smb$status) {
        print fmt("[SMB] SMB error: %s", c$smb$status);
    }
    }
```

---

## 8. SMB3 加密

### 8.1 SMB 加密检测

SMB3 引入了端到端加密，Zeek 可以检测加密状态。

```zeek
# 检测 SMB 加密
event smb_request(c: connection, hdr: SMB::Header,
                  command: SMB::Command, sub_command: string)
    {
    if (c$smb?$encrypted && c$smb$encrypted) {
        print fmt("[SMB] Encrypted SMB3 connection to %s", c$id$resp_h);
    }
    }
```

---

## 9. 实战示例

### 9.1 完整 SMB 监控脚本

```zeek
@load base/protocols/smb

# SMB 监控配置
redef SMB::disable_cert_log = F;

# 告警阈值
const alert_threshold = 5;
global smb_errors: table[addr] of count;

event smb_request(c: connection, hdr: SMB::Header,
                  command: SMB::Command, sub_command: string)
    {
    # 统计错误
    if (c$smb?$status && c$smb$status != "SUCCESS") {
        local client = c$id$orig_h;
        if (client !in smb_errors) {
            smb_errors[client] = 0;
        }
        smb_errors[client] += 1;

        if (smb_errors[client] > alert_threshold) {
            NOTICE([$note = SMB_BRUTE_FORCE,
                    $msg = fmt("SMB errors from %s: %d",
                               client, smb_errors[client]),
                    $conn = c]);
        }
    }
    }

event smb_connect(c: connection, hdr: SMB::Header, path: string,
                  share_type: string, share_flags: count)
    {
    # 检测敏感共享
    if (/C\$|ADMIN\$|PRINT\$/ in path) {
        print fmt("[SMB] Admin share access: %s to %s by %s",
                  c$id$orig_h, path,
                  c$smb$user ? c$smb$user : "anonymous");
    }

    # 检测异常共享
    if (share_type == "DISK" && path == "IPC$") {
        NOTICE([$note = SMB_ENUMERATION,
                $msg = fmt("IPC$ access from %s", c$id$orig_h),
                $conn = c]);
    }
    }

event smb_file_open(c: connection, hdr: SMB::Header, fid: string,
                    name: string, path: string)
    {
    # 检测可疑文件类型
    local dangerous_ext = /\.(exe|dll|bat|cmd|ps1|vbs|js|jar|scr|pif)$/i;
    if (dangerous_ext in name) {
        NOTICE([$note = SMB_MALWARE,
                $msg = fmt("Suspicious file transfer: %s", name),
                $conn = c]);
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek SMB 分析器的核心能力：

| 组件              | 说明                                          |
| ----------------- | --------------------------------------------- |
| **SMB::Info**     | SMB 日志核心 record，包含会话、命令、文件操作 |
| **smb_connect**   | 树连接事件，检测共享访问                      |
| **smb_file_open** | 文件打开事件                                  |
| **smb_write**     | 文件写入事件                                  |
| **smb_files.log** | SMB 文件传输日志                              |
| **NTLM 认证**     | SMB 认证分析                                  |

SMB 日志对于检测：

- 横向移动（PSEXEC/WMI）
- 敏感文件访问
- 恶意文件传输
- SMB 枚举
- NTLM 暴力破解

至关重要，是 Windows 环境安全监控的核心数据源。
