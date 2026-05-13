---
title: "Zeek 深度探索 (二十二)：文件分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - file-analysis
  - files.log
  - hash
  - malware
  - extraction
description: "深入解析 Zeek 文件分析——文件提取、file-analysis 框架、哈希计算、files.log、恶意软件检测"
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
> 17. [[2026-04-15-zeek-deep-dive-ch17-smtp|第十七章：SMTP 分析]]
> 18. [[2026-04-15-zeek-deep-dive-ch18-rdp|第十八章：RDP 分析]]
> 19. [[2026-04-15-zeek-deep-dive-ch19-kafka|第十九章：Kafka 集成]]
> 20. [[2026-04-15-zeek-deep-dive-ch20-conn|第二十章：连接分析]]
> 21. [[2026-04-15-zeek-deep-dive-ch21-weirds|第二十一章：Weird 日志]]
> 22. **第二十二章：文件分析**

---

## 1. 文件分析概述

Zeek 的文件分析框架可以提取和分析通过协议传输的文件，生成文件哈希、提取元数据、检测恶意软件。

### 1.1 文件分析框架位置

```
$ZEEK_HOME/scripts/base/files/
├── main.zeek           # 文件分析主框架
├── extract.zeek       # 文件提取
├── hash.zeek          # 哈希计算
├── magic.zeek         # 文件类型识别
├── anime.zeek        # 协议分析器集成
└── ...

$ZEEK_HOME/scripts/base/protocols/http/
├── file-analysis.zeek  # HTTP 文件分析

$ZEEK_HOME/scripts/base/protocols/smtp/
├── file-analysis.zeek  # SMTP 文件分析
```

### 1.2 文件分析架构

```
┌─────────────────────────────────────────────────────────────┐
│                    文件分析架构                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Protocol Analyzer (HTTP/SMTP/SMB/FTP)                       │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  File Analysis Framework                               │  │
│  │  ├── File State Machine                                │  │
│  │  ├── Content哈ber (MD5/SHA1/SHA256)                    │  │
│  │  ├── File Extractor                                   │  │
│  │  └── Magic Identification                             │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  File Events                                           │  │
│  │  file_new, file_over_new_connection, file_hash, etc.  │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  files.log + extracted files                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 文件日志格式

### 2.1 files.log 字段详解

```zeek
type Files::Info = record {
    # 文件标识
    ts: time;              # 首次看到时间
    fuid: string;          # 文件唯一标识符

    # 连接信息
    uid: string;           # 关联连接 UID
    id: conn_id;           # 关联连接 4-tuple

    # 文件分析器来源
    analyzer: set[string];  # 分析器类型
    analyzer_ids: set[string];  # 分析器 ID

    # 文件信息
    mime: string;          # MIME 类型
    filename: string &optional;  # 文件名

    # 大小
    size: int64;           # 文件大小
    depth: count;          # 文件在会话中的深度

    # 哈希
    md5: string &optional;
    sha1: string &optional;
    sha256: string &optional;

    # 提取
    extracted: string &optional;  # 提取的文件路径
    extracted_cutoff: bool &optional;  # 是否因大小限制被截断
    extracted_size: int64 &optional;  # 提取的文件大小

    # 传输
    total_bytes: int64 &optional;   # 总字节数
    disk_bytes: int64 &optional;    # 写入磁盘字节数

    # 捕获
    missing_bytes: count &optional;  # 丢失的字节
    overflow_bytes: count &optional;  # 溢出的字节

    # 时间
    timedout: bool &optional;      # 是否超时

    # 密码保护
    password: string &optional;    # 检测到密码保护
};
```

### 2.2 files.log 示例

```
#fields ts fuid uid id.orig_h id.orig_p id.resp_h id.resp_p analyzer mime filename size md5 sha256
1672531200.123456 F12345abc Cx1234abcd 192.168.1.100 52341 93.184.216.34 443 HTTP::ANALYZER text/html index.html 1523 d41d8cd98f00b204e9800998ecf8427e e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 /tmp/zeek-extract-F12345abc 1523
```

### 2.3 主要字段说明

| 字段 | 类型 | 说明 |
|------|------|------|
| `fuid` | string | 文件唯一标识符 |
| `uid` | string | 关联连接 UID |
| `id` | conn_id | 关联连接 4-tuple |
| `analyzer` | set[string] | 分析器类型 (HTTP, SMTP, SMB, etc.) |
| `mime` | string | MIME 类型 |
| `filename` | string | 文件名（如有） |
| `size` | int64 | 文件大小 |
| `md5` | string | MD5 哈希 |
| `sha1` | string | SHA1 哈希 |
| `sha256` | string | SHA256 哈希 |
| `extracted` | string | 提取文件路径 |

---

## 3. 文件事件

### 3.1 file_new 事件

```zeek
event file_new(f: fa_file)
```

检测到新文件时触发。

```zeek
event file_new(f: fa_file)
    {
    print fmt("[FILE] New file detected: %s", f$tx_hosts);
    print fmt("[FILE] MIME: %s, Size: %d", f$ mime, f$size);
    }
```

### 3.2 file_over_new_connection 事件

```zeek
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
```

文件通过连接传输时触发。

```zeek
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    local direction = is_orig ? "orig -> resp" : "resp -> orig";
    print fmt("[FILE] File on connection: %s %s (%s)",
              c$id$orig_h, c$id$resp_h, direction);

    # 记录文件元数据
    if (f$ mime != "") {
        print fmt("[FILE] MIME: %s", f$mime);
    }
    if (f?$filename) {
        print fmt("[FILE] Filename: %s", f$filename);
    }
    }
```

### 3.3 file_hash 事件

```zeek
event file_hash(f: fa_file, kind: string, hash: string)
```

文件哈希计算完成时触发。

```zeek
event file_hash(f: fa_file, kind: string, hash: string)
    {
    print fmt("[FILE HASH] %s: %s = %s", f$fuid, kind, hash);

    # 记录哈希值
    if (kind == "md5") {
        print fmt("[FILE] MD5: %s", hash);
    }
    }
```

### 3.4 file_extraction 事件

```zeek
event file_extraction(f: fa_file, path: string)
```

文件提取完成时触发。

```zeek
event file_extraction(f: fa_file, path: string)
    {
    print fmt("[FILE] Extracted: %s -> %s (size: %d)", f$fuid, path, f$size);

    # 可以在这里进行后续分析
    # 例如：提交到恶意软件分析平台
    }
```

### 3.5 file_gap 事件

```zeek
event file_gap(f: fa_file, offset: count, length: count)
```

文件传输中出现数据空洞时触发。

```zeek
event file_gap(f: fa_file, offset: count, length: count)
    {
    print fmt("[FILE] Gap in %s at offset %d, length %d",
              f$fuid, offset, length);

    # 可能表示数据丢失或截断
    if (f?$missing_bytes) {
        print fmt("[FILE] Total missing: %d bytes", f$missing_bytes);
    }
    }
```

### 3.6 file_state_remove 事件

```zeek
event file_state_remove(f: fa_file)
```

文件分析完成，状态移除时触发。

```zeek
event file_state_remove(f: fa_file)
    {
    print fmt("[FILE] File analysis complete: %s", f$fuid);

    # 打印文件摘要
    print fmt("[FILE] Size: %d, MIME: %s", f$size, f$mime);

    if (f?$md5) {
        print fmt("[FILE] MD5: %s", f$md5);
    }
    if (f?$sha256) {
        print fmt("[FILE] SHA256: %s", f$sha256);
    }
    }
```

---

## 4. 文件分析配置

### 4.1 提取配置

```zeek
# 文件提取目录
redef FileExtract::default_extract_dir = "/tmp/zeek-extract";

# 启用提取
redef FileExtract::extract_all_files = F;
redef FileExtract::total_bytes_capture = 100MB;  # 最大捕获总大小
redef FileExtract::max_file_size = 25MB;         # 单文件最大大小

# MD5/SHA1/SHA256 哈希
redef FileAnalysis::md5_enabled = T;
redef FileAnalysis::sha1_enabled = T;
redef FileAnalysis::sha256_enabled = T;
```

### 4.2 协议配置

```zeek
# HTTP 文件提取
redef HTTP::default_capture_file = T;
redef HTTP::extract_all_files = F;

# SMTP 文件提取
redef SMTP::extract_all_scripts = T;
redef SMTP::extract_all_executables = T;
redef SMTP::extract_all_encrypted = F;

# SMB 文件提取
redef SMB::capture_all_file_transfers = F;
```

### 4.3 MIME 类型配置

```zeek
# 要分析的 MIME 类型
redef FileAnalysis::mime_types_to_analyze: set[string] = {
    "application/pdf",
    "application/msword",
    "application/vnd.ms-excel",
    "application/x-executable",
    "application/x-java-applet",
    "application/x-shockwave-flash",
    "application/zip",
    "text/html",
    "text/plain"
};
```

### 4.4 文件名匹配

```zeek
# 要提取的文件名模式
redef FileExtract::filename_prefixes = set(
    "inline_executable",
    "untrusted_code"
);
```

---

## 5. 文件哈希计算

### 5.1 哈希类型

Zeek 支持计算三种哈希：
- MD5 (128-bit)
- SHA1 (160-bit)
- SHA256 (256-bit)

### 5.2 哈希事件处理

```zeek
global file_hashes: table[string] of string;  # fuid -> md5

event file_hash(f: fa_file, kind: string, hash: string)
    {
    if (kind == "md5") {
        file_hashes[f$fuid] = hash;
        print fmt("[HASH] %s: MD5 = %s", f$fuid, hash);
    }
    }
```

### 5.3 恶意软件检测

```zeek
# 已知恶意软件哈希库
global malicious_hashes: set[string] = {
    "d41d8cd98f00b204e9800998ecf8427e",  # 示例
    "098f6bcd4621d373cade4e832627b4f6",
    "ad0234829205b9033196ba818f7a872b"
};

event file_hash(f: fa_file, kind: string, hash: string)
    {
    if (kind == "md5" && hash in malicious_hashes) {
        print fmt("[ALERT] Malicious file detected: %s (MD5: %s)",
                  f$fuid, hash);

        NOTICE([$note = MALWARE_DETECTED,
                $msg = fmt("Malicious file detected: MD5=%s, file=%s",
                          hash, f?$filename ? f$filename : "unknown"),
                $conn = c]);
    }
    }
```

---

## 6. 文件提取实战

### 6.1 提取 HTTP 下载文件

```zeek
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    # 只关注响应方向的文件
    if (!is_orig) {
        print fmt("[HTTP FILE] Downloaded: %s (MIME: %s, Size: %d)",
                  f?$filename ? f$filename : "unknown",
                  f$mime, f$size);
    }
    }
```

### 6.2 提取可执行文件

```zeek
global suspicious_mime = set(
    "application/x-executable",
    "application/x-msdownload",
    "application/x-sh",
    "application/x-msdos-program",
    "application/x-dosexec"
);

event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    if (f$mime in suspicious_mime) {
        print fmt("[ALERT] Executable detected: %s from %s (MIME: %s)",
                  f?$filename ? f$filename : f$fuid,
                  c$id$orig_h, f$mime);

        NOTICE([$note = EXECUTABLE_DOWNLOAD,
                $msg = fmt("Executable file detected: %s (MIME: %s)",
                          f?$filename ? f$filename : f$fuid, f$mime),
                $conn = c]);
    }
    }
```

### 6.3 提取敏感文档

```zeek
global sensitive_types = set(
    "application/vnd.ms-excel",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/msword",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
);

event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    if (f$mime in sensitive_types) {
        print fmt("[INFO] Sensitive document: %s (MIME: %s, Size: %d)",
                  f?$filename ? f$filename : "unknown",
                  f$mime, f$size);

        # 记录但不告警
        print fmt("[DOC] Extracted to: %s", f?$extracted ? f$extracted : "not extracted");
    }
    }
```

### 6.4 统计文件传输

```zeek
global file_stats: table[string] of count;  # mime -> count
global total_bytes = 0;

event file_state_remove(f: fa_file)
    {
    if (f$mime != "") {
        if (f$mime !in file_stats) {
            file_stats[f$mime] = 0;
        }
        file_stats[f$mime] += 1;
        total_bytes += f$size;

        print fmt("[STATS] File type %s: %d files, %d total bytes",
                  f$mime, file_stats[f$mime], total_bytes);
    }
    }
```

### 6.5 文件名提取

```zeek
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    # 提取 Content-Disposition 中的文件名
    if (f?$filename) {
        print fmt("[FILE] Filename: %s", f$filename);

        # 检测可疑文件名
        if (/\.exe$|\.dll$|\.bat$|\.ps1$|\.vbs$/ in f$filename) {
            NOTICE([$note = SUSPICIOUS_FILENAME,
                    $msg = fmt("Suspicious filename: %s from %s",
                              f$filename, c$id$orig_h),
                    $conn = c]);
        }

        # 检测路径遍历
        if (/\.\.\// in f$filename) {
            NOTICE([$note = PATH_TRAVERSAL,
                    $msg = fmt("Path traversal in filename: %s", f$filename),
                    $conn = c]);
        }
    }
    }
```

---

## 7. SMTP 附件分析

### 7.1 邮件附件事件

```zeek
event file_over_new_connection(f: fa_file, c: connection, is_orig: bool)
    {
    # 检查是否为 SMTP 会话的文件
    if (c?$smtp) {
        print fmt("[EMAIL] Attachment: %s (MIME: %s, Size: %d)",
                  f?$filename ? f$filename : "unknown",
                  f$mime, f$size);

        # 记录附件信息
        if (f?$md5) {
            print fmt("[EMAIL] MD5: %s", f$md5);
        }
    }
    }
```

### 7.2 恶意邮件附件检测

```zeek
global malicious_attachments: table[string] of string;  # md5 -> description

event file_hash(f: fa_file, kind: string, hash: string)
    {
    if (kind == "md5" && hash in malicious_attachments) {
        print fmt("[ALERT] Malicious email attachment: %s (MD5: %s)",
                  malicious_attachments[hash], hash);

        NOTICE([$note = MALICIOUS_EMAIL_ATTACHMENT,
                $msg = fmt("Malicious attachment: %s (MD5: %s)",
                          malicious_attachments[hash], hash),
                $conn = c]);
    }
    }
```

---

## 8. 文件分析与威胁情报

### 8.1 VirusTotal 集成

```zeek
# 注意：需要 API key
global vt_api_key = "YOUR_VIRUSTOTAL_API_KEY";

event file_state_remove(f: fa_file)
    {
    if (f?$sha256) {
        # 提交到 VirusTotal
        local url = fmt("https://www.virustotal.com/api/v3/files/%s", f$sha256);
        print fmt("[VT] Checking: %s", url);
        # 实际使用需要 HTTP 客户端
    }
    }
```

### 8.2 本地威胁情报匹配

```zeek
# 加载外部威胁情报
global malicious_hashes: set[string];

event zeek_init()
    {
    # 从文件加载恶意哈希
    # local fh = open("/opt/zeek/etc/malicious-hashes.txt");
    # while (line = getline(fh)) {
    #     add malicious_hashes[line];
    # }
    # close(fh);
    }

event file_hash(f: fa_file, kind: string, hash: string)
    {
    if (kind == "sha256" && hash in malicious_hashes) {
        NOTICE([$note = MALICIOUS_FILE,
                $msg = fmt("Known malicious file: %s (SHA256: %s)",
                          f?$filename ? f$filename : f$fuid, hash),
                $conn = c]);
    }
    }
```

---

## 9. 提取文件处理

### 9.1 提取后处理

```zeek
event file_extraction(f: fa_file, path: string)
    {
    print fmt("[EXTRACT] File extracted to: %s", path);

    # 记录提取文件路径
    local extract_log = open("/var/log/zeek/extracted-files.log");
    print extract_log, fmt("%s | %s | %s | %d",
                           network_time(), f$fuid, path, f$size);
    close(extract_log);

    # 可以触发外部分析
    # system(fmt("python3 /opt/zeek/scripts/analyze.py %s", path));
    }
```

### 9.2 文件大小限制

```zeek
# 配置单文件最大提取大小
redef FileExtract::max_file_size = 10MB;

# 配置总捕获大小
redef FileExtract::total_bytes_capture = 1GB;

event file_extraction(f: fa_file, path: string)
    {
    if (f$extracted_cutoff) {
        print fmt("[WARNING] File extraction cut off at size limit: %s", f$fuid);
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek 文件分析框架的核心能力：

| 组件 | 说明 |
|------|------|
| **files.log** | 文件分析主日志，记录所有检测到的文件 |
| **Files::Info** | 文件信息的 record 类型 |
| **file_new** | 检测到新文件事件 |
| **file_over_new_connection** | 文件在连接中传输事件 |
| **file_hash** | 文件哈希计算完成事件 |
| **file_extraction** | 文件提取完成事件 |
| **MD5/SHA1/SHA256** | 三种哈希算法支持 |

文件分析的关键配置：
- `FileExtract::default_extract_dir` - 提取目录
- `FileExtract::max_file_size` - 单文件大小限制
- `FileAnalysis::md5/sha1/sha256_enabled` - 哈希开关

文件分析对于检测：
- 恶意软件传播
- 数据泄露
- 可执行文件下载
- 邮件附件威胁
- 文档敏感信息

下一章我们将讨论签名检测——Zeek 如何使用签名进行模式匹配和威胁检测。
