---
title: "Zeek 深度探索 (十三)：TLS 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - tls
  - ssl
  - https
  - certificate
  - ja3
  - jarm
description: "深入解析 Zeek TLS 分析器——TLS::Info record、证书信息、SNI/JA3/JARM 指纹、日志输出、TLS 脚本事件"
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
> 13. **第十三章：TLS 分析**

---

## 1. TLS 分析器概述

Zeek 内置 TLS/SSL 协议解析器，位于 `base/protocols/ssl` 目录。TLS 分析器可以解密握手过程、提取证书信息、计算 JA3/JARM 指纹。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/ssl/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # TLS::Info 等类型定义
├── heartbeat.zeek     # Heartbleed 检测
├── ransomware.zeek    # 勒索软件检测
└── ...
```

### 1.2 TLS 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    TLS 分析器架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  TCP Connection                                              │
│       ↓                                                      │
│  TLS Handshake Parser                                        │
│  ├── ClientHello (SNI, TLS version, ciphers)                │
│  ├── ServerHello (cipher, extensions)                       │
│  ├── Certificate (chain, subject, issuer)                   │
│  └── ServerHelloDone                                         │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  ssl_client_hello   事件                              │  │
│  │  ssl_server_hello   事件                              │  │
│  │  ssl_certificate    事件                              │  │
│  │  ssl_conn_attempted 事件                             │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  TLS::Info record 填充                                       │
│       ↓                                                      │
│  ssl.log 输出                                                 │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. TLS 日志格式

### 2.1 ssl.log 字段详解

```zeek
type SSL::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;          # 4-tuple

    # 连接状态
    version: string;       # TLS 版本 (TLSv1.2/TLSv1.3)
    cipher: string;        # 协商的加密套件
    server_name: string;   # SNI (Server Name Indication)
    session_id: string;    # 会话 ID
    resumed: bool;         # 是否恢复会话
    last_passive: bool;    # 是否被动解析

    # 证书信息
    cert_chain_fuids: vector of string;  # 证书链文件 UID
    cert_chain: vector of string;        # 证书链 PEM 数据
    cert: string &optional;               # 端点证书 PEM
    cert_subject: string;               # 证书主题
    cert_issuer: string;                 # 证书颁发者
    cert_serial: string;                 # 证书序列号
    cert_issuer_subject: string;         # 颁发者主题
    cert_sig_alg: string;                # 签名算法
    cert_key_alg: string;                # 密钥算法
    cert_key_type: string;               # 密钥类型 (RSA/DSA/ECDSA)
    cert_key_length: count;             # 密钥长度
    cert_expiry: time;                  # 证书过期时间
    validation_status: string;          # 证书验证状态

    # JA3/JARM 指纹
    ja3: string;                        # JA3 客户端指纹
    ja3s: string;                       # JA3S 服务器指纹

    # JARM 指纹
    jarm: string;                       # JARM 模糊指纹

    # 抖动指纹
    dh_bits: count;                     # DH 密钥交换位长

    # 异常标志
    suspicious: bool;                   # 可疑标志
    severities: vector of count;        # 异常严重级别

    # 内部
    next_protocol: string;              # ALPN 协议
    tunnel_parent: conn_id &optional;   # 隧道父连接
};
```

### 2.2 ssl.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	version	cipher	server_name	resumed	last_passive		serial	cert_subject	cert_issuer		cert_chain_fuids
1672531200.123456	Cx1234abcd	192.168.1.100	49234	93.184.216.34	443	TLSv13	TLS_AES_256_GCM_SHA384	example.com	F	F	0x01	/C=US/ST=California/L=Los Angeles/O=Example Inc	/C=US/St=...	[Fy1234abcd]
1672531210.234567	Dy5678efgh	192.168.1.100	49235	8.8.8.1	443	TLSv12	TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256	-	F	F	-	-	-	-
```

---

## 3. JA3/JARM 指纹

### 3.1 JA3 指纹原理

JA3（Jefferson Audio ja3）是一种 TLS 客户端指纹算法，通过对 ClientHello 中的以下字段计算 MD5 哈希：

1. TLS 版本
2. 加密套件列表（按出现顺序）
3. 所有扩展的列表
4. elliptic_curves (仅 TLS 1.3)
5. elliptic_curve_point_formats

```zeek
# JA3 计算方式
# 示例 JA3: 771,4865-4866-4867,0-23-65281-10-16-5,23-24,0

# JA3 字段解释：
# 771           = TLS 版本 (0x0303 = TLS 1.2)
# 4865-4866... = 加密套件列表 (16进制)
# 0-23-65...   = 扩展列表
# 23-24        = elliptic_curves
# 0            = elliptic_curve_point_formats
```

### 3.2 JARM 指纹原理

JARM 是一种主动模糊 TLS 服务器指纹，通过发送 10 个不同的 ClientHello 并分析服务器响应模式。

```zeek
# JARM 示例
# 2ad2ad16d21ad21d21ad21d21ad21ad21ad21d21ad1d1ad1ad1ad1ad1ad1ad1

# JARM 结构：
# 每个 "ad" 代表一个密码套件的响应特征
```

### 3.3 指纹应用

```zeek
# 识别恶意软件 TLS 特征
const malicious_ja3 = {
    "5d5c5c5c5c5c5c5c5c5c5c5c5c5c5c",
    "a1b1c1d1e1f1a1b1c1d1e1f1a1b1c1d1",
};

const suspicious_jarm = {
    "2ad2ad16d21ad21d21ad21d21ad21ad21ad21d21ad1d1ad1ad1ad1ad1ad1ad1",
};

event ssl_client_hello(c: connection, version: count, ciphers: index_vec,
                       comp: index_vec, extensions: extension_vec)
    {
    if (c$ssl?$ja3) {
        # 检测恶意 JA3
        if (c$ssl$ja3 in malicious_ja3) {
            NOTICE([$note = MALWARE_TLS,
                    $msg = fmt("Malware TLS fingerprint: %s from %s",
                               c$ssl$ja3, c$id$orig_h),
                    $conn = c]);
        }
    }

    if (c$ssl?$jarm && c$ssl$jarm in suspicious_jarm) {
        NOTICE([$note = SUSPICIOUS_TLS_SERVER,
                $msg = fmt("Suspicious TLS server: %s", c$id$resp_h),
                $conn = c]);
    }
    }
```

---

## 4. TLS 脚本事件

### 4.1 ssl_client_hello 事件

```zeek
event ssl_client_hello(c: connection, version: count, ciphers: index_vec,
                       comp: index_vec, extensions: extension_vec)
```

触发时机：解析完 TLS ClientHello 后。

```zeek
# 提取 SNI 和 JA3
event ssl_client_hello(c: connection, version: count, ciphers: index_vec,
                       comp: index_vec, extensions: extension_vec)
    {
    if (c$ssl?$server_name) {
        print fmt("[TLS] Client %s connecting to %s (JA3: %s)",
                  c$id$orig_h, c$ssl$server_name,
                  c$ssl$ja3);
    }
    }
```

### 4.2 ssl_server_hello 事件

```zeek
event ssl_server_hello(c: connection, version: count, cipher: count,
                       comp: count, extensions: extension_vec)
```

触发时机：解析完 TLS ServerHello 后。

### 4.3 ssl_certificate 事件

```zeek
event ssl_certificate(c: connection, cert: X509, chain: bool)
```

触发时机：解析到证书时。

```zeek
# 证书分析
event ssl_certificate(c: connection, cert: X509, chain: bool)
    {
    local subject = cert$subject;
    local issuer = cert$issuer;
    local serial = cert$serial;

    print fmt("[TLS] Certificate: %s", subject);
    print fmt("       Issuer: %s", issuer);
    print fmt("       Serial: %s", serial);

    # 检测自签名证书
    if (subject == issuer) {
        print fmt("[TLS] Self-signed certificate from %s", c$id$resp_h);
    }
    }
```

### 4.4 ssl_conn_attempted 事件

```zeek
event ssl_conn_attempted(c: connection, reason: string)
```

触发时机：TLS 连接尝试失败时。

---

## 5. 证书分析

### 5.1 证书过期检测

```zeek
# 检测过期证书
event ssl_certificate(c: connection, cert: X509, chain: bool)
    {
    if (c$ssl?$cert_expiry) {
        local now = network_time();
        local expiry = c$ssl$cert_expiry;

        if (expiry < now) {
            NOTICE([$note = EXPIRED_CERT,
                    $msg = fmt("Expired certificate on %s (expired %s)",
                               c$id$resp_h, expiry),
                    $conn = c]);
        } else if (expiry - now < 7 days) {
            NOTICE([$note = EXPIRING_CERT,
                    $msg = fmt("Certificate expiring soon on %s (expires %s)",
                               c$id$resp_h, expiry),
                    $conn = c]);
        }
    }
    }
```

### 5.2 证书链验证

```zeek
# 分析证书链完整性
event ssl_certificate(c: connection, cert: X509, chain: bool)
    {
    if (c$ssl?$cert_chain_fuids && |c$ssl$cert_chain_fuids| > 0) {
        print fmt("[TLS] Certificate chain (%d certs) for %s",
                  |c$ssl$cert_chain_fuids| + 1,
                  c$ssl$server_name);

        for (fuid in c$ssl$cert_chain_fuids) {
            print fmt("       Intermediate: %s", fuid);
        }
    }

    if (c$ssl?$validation_status) {
        if (c$ssl$validation_status != "ok") {
            NOTICE([$note = INVALID_CERT,
                    $msg = fmt("Certificate validation failed for %s: %s",
                               c$id$resp_h, c$ssl$validation_status),
                    $conn = c]);
        }
    }
    }
```

### 5.3 检测恶意证书

```zeek
# 检测已知恶意证书序列号
global malicious_cert_serials = {
    "0x000000000000000000000000000001",
    "0xdeadbeef1234567890abcdef123456",
};

event ssl_certificate(c: connection, cert: X509, chain: bool)
    {
    if (c$ssl?$cert_serial && c$ssl$cert_serial in malicious_cert_serials) {
        NOTICE([$note = MALICIOUS_CERT,
                $msg = fmt("Known malicious certificate serial: %s",
                           c$ssl$cert_serial),
                $conn = c]);
    }

    # 检测 Let's Encrypt 证书滥用
    if (c$ssl?$cert_issuer && /letsencrypt|let's encrypt/i in c$ssl$cert_issuer) {
        print fmt("[TLS] Let's Encrypt certificate for %s",
                  c$ssl$server_name);
    }
    }
```

---

## 6. TLS 配置选项

### 6.1 主要配置项

```zeek
# 日志详细程度
redef SSL::log_cert_violations = T;     # 记录证书违规
redef SSL::log_passwords = F;           # 不记录 TLS 捕获的密码

# 握手超时
redef SSL::handshake_lifetime = 10 secs;

# 证书验证
redef SSL::verify_cert = F;             # 禁用证书验证（需要 CA bundle）
redef SSL::ca_store = "/etc/ssl/certs/ca-certificates.crt";

# JA3/JARM
redef SSL::extract_ja3 = T;             # 启用 JA3 提取
redef SSL::jarm_fingerprint = T;       # 启用 JARM 计算
```

### 6.2 服务器端验证

```zeek
# 服务器端 TLS 分析
redef SSL::server_analytics = T;
redef SSL::log_server_cipher_suites = T;
```

---

## 7. TLS 版本检测

### 7.1 检测旧版本 TLS

```zeek
# 检测 TLS 1.0/1.1 使用（已知脆弱版本）
event ssl_client_hello(c: connection, version: count, ciphers: index_vec,
                       comp: index_vec, extensions: extension_vec)
    {
    if (version == 0x0301) {
        NOTICE([$note = OLD_TLS_VERSION,
                $msg = fmt("TLS 1.0 connection from %s to %s",
                           c$id$orig_h, c$id$resp_h),
                $conn = c]);
    } else if (version == 0x0302) {
        NOTICE([$note = OLD_TLS_VERSION,
                $msg = fmt("TLS 1.1 connection from %s to %s",
                           c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }
    }
```

### 7.2 检测弱加密套件

```zeek
# 检测弱加密套件
const weak_ciphers = {
    "TLS_RSA_WITH_RC4_128_SHA",
    "TLS_RSA_WITH_3DES_EDE_CBC_SHA",
    "TLS_ECDHE_RSA_WITH_RC4_128_SHA",
};

event ssl_server_hello(c: connection, version: count, cipher: count,
                       comp: count, extensions: extension_vec)
    {
    if (c$ssl?$cipher && c$ssl$cipher in weak_ciphers) {
        NOTICE([$note = WEAK_CIPHER,
                $msg = fmt("Weak cipher %s used by %s to %s",
                           c$ssl$cipher, c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }
    }
```

---

## 8. Heartbleed 检测

### 8.1 Heartbleed 漏洞

Heartbleed（CVE-2014-0160）是 OpenSSL 的 heartbeat 扩展漏洞，允许攻击者读取服务器内存。

```zeek
# Heartbleed 检测
event heartbeat_message(c: connection, uid: string, is_orig: bool,
                        payload_length: count, payload: string)
    {
    # 异常大的 heartbeat 响应
    if (payload_length > 200) {
        NOTICE([$note = HEARTBLEED,
                $msg = fmt("Possible Heartbleed: large heartbeat response (%d bytes) from %s",
                           payload_length, c$id$resp_h),
                $conn = c]);
    }
    }
```

---

## 9. 实战示例

### 9.1 完整 TLS 监控脚本

```zeek
@load base/protocols/ssl

# TLS 监控配置
redef SSL::log_cert_violations = T;
redef SSL::extract_ja3 = T;

# 已知恶意 JA3
global threat_ja3: set[string] = {
    "malware-ja3-hash-1",
    "malware-ja3-hash-2",
};

# 敏感域名
const sensitive_sni = /.*\.gov|.*\.mil|.*\.edu/i;

event ssl_client_hello(c: connection, version: count, ciphers: index_vec,
                       comp: index_vec, extensions: extension_vec)
    {
    # JA3 威胁检测
    if (c$ssl?$ja3 && c$ssl$ja3 in threat_ja3) {
        NOTICE([$note = MALWARE_TLS,
                $msg = fmt("Malware TLS: JA3 %s from %s",
                           c$ssl$ja3, c$id$orig_h),
                $conn = c]);
    }

    # 敏感域名 HTTPS 连接
    if (c$ssl?$server_name && sensitive_sni in c$ssl$server_name) {
        print fmt("[TLS] Sensitive domain: %s from %s",
                  c$ssl$server_name, c$id$orig_h);
    }

    # 检测 TLS 1.0/1.1
    if (version < 0x0303) {
        NOTICE([$note = DEPRECATED_TLS,
                $msg = fmt("Deprecated TLS %d.%d from %s to %s",
                           version / 256, version % 256,
                           c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }
    }

event ssl_certificate(c: connection, cert: X509, chain: bool)
    {
    # 自签名证书
    if (c$ssl$cert_subject == c$ssl$cert_issuer) {
        if (c$ssl?$server_name && sensitive_sni !in c$ssl$server_name) {
            NOTICE([$note = SELF_SIGNED_CERT,
                    $msg = fmt("Self-signed certificate for %s",
                               c$ssl$server_name),
                    $conn = c]);
        }
    }

    # 证书过期
    if (c$ssl?$cert_expiry && c$ssl$cert_expiry < network_time()) {
        NOTICE([$note = EXPIRED_CERT,
                $msg = fmt("Expired certificate for %s (expired %s)",
                           c$ssl$server_name, c$ssl$cert_expiry),
                $conn = c]);
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek TLS 分析器的核心能力：

| 组件 | 说明 |
|------|------|
| **SSL::Info** | TLS 日志核心 record，包含连接、证书、指纹信息 |
| **ssl_client_hello** | TLS ClientHello 事件，可提取 SNI、JA3 |
| **ssl_server_hello** | TLS ServerHello 事件 |
| **ssl_certificate** | 证书解析事件，包含完整的证书字段 |
| **JA3** | 客户端指纹，用于恶意软件检测 |
| **JARM** | 服务器指纹，用于服务识别 |

TLS 日志可用于：
- 恶意软件 TLS 特征检测
- 证书过期/自签名监控
- TLS 版本合规检测
- 弱加密套件检测
- Heartbleed 等漏洞检测
