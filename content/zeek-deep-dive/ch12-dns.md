---
title: "Zeek 深度探索 (十二)：DNS 分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - dns
  - protocol-analysis
  - domain-analysis
description: "深入解析 Zeek DNS 分析器——DNS::Info record、查询/响应日志、AAAA/A/AAAA 记录类型、DNSt隧道检测、DNS 脚本事件"
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
> 12. **第十二章：DNS 分析**

---

## 1. DNS 分析器概述

Zeek 内置 DNS 协议解析器，位于 `base/protocols/dns` 目录。DNS 是网络基础设施协议，DNS 日志对于威胁检测和威胁狩猎至关重要。

### 1.1 协议框架位置

```
$ZEEK_HOME/scripts/base/protocols/dns/
├── main.zeek          # 主脚本，事件绑定
├── types.zeek         # DNS::Info 等类型定义
└── ...
```

### 1.2 DNS 分析器架构

```
┌─────────────────────────────────────────────────────────────┐
│                    DNS 分析器架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  UDP/TCP DNS Query                                           │
│       ↓                                                      │
│  DNS Header Parser (ID, Flags, QDCOUNT)                    │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  dns_request    事件 (query, qtype, qclass)           │  │
│  │  dns_reply      事件 (id, query, qtype, answers)      │  │
│  │  dns_query      事件 (name, type, class)              │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  DNS::Info record 填充                                      │
│       ↓                                                      │
│  dns.log 输出                                                │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. DNS 日志格式

### 2.1 dns.log 字段详解

```zeek
type DNS::Info = record {
    # 连接标识
    ts: time;              # 时间戳
    uid: string;           # 连接 UID
    id: conn_id;           # 4-tuple

    # 查询信息
    trans_id: count;       # DNS 事务 ID
    rtt: interval;         # 查询到响应的时间
    query: string;         # 查询域名
    qclass: count;         # 查询类别 (通常 1 = IN)
    qclass_name: string;   # 类别名称
    qtype: count;          # 查询类型 (A/AAAA/MX/TXT 等)
    qtype_name: string;    # 类型名称

    # 响应标志
    rcode: count;          # 响应码 (0=NoError, 3=NXDOMAIN 等)
    rcode_name: string;    # 响应码名称
    AA: bool;              # Authoritative Answer
    TC: bool;              # Truncated
    RD: bool;              # Recursion Desired
    RA: bool;              # Recursion Available

    # 响应数据
    answers: vector of string;    # 答案 (IP/域名等)
    TTLs: vector of count;        # TTL 值
    rejected: bool;               # 查询是否被拒绝
};
```

### 2.2 DNS 查询类型

| qtype | 名称  | 说明       |
| ----- | ----- | ---------- |
| 1     | A     | IPv4 地址  |
| 5     | CNAME | 别名记录   |
| 15    | MX    | 邮件交换   |
| 28    | AAAA  | IPv6 地址  |
| 2     | NS    | 域名服务器 |
| 12    | PTR   | 指针记录   |
| 33    | SRV   | 服务定位   |
| 16    | TXT   | 文本记录   |
| 255   | ANY   | 所有记录   |

### 2.3 dns.log 示例

```
#fields	ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	proto	trans_id	rtt	query	qclass	qclass_name	qtype	qtype_name	rcode	rcode_name	AA	TC	RD	RA	Z	answers	TTLs	rejected
1672531200.123456	Cx1234abcd	192.168.1.100	52341	8.8.8.8	53	udp	0x1234	0.025	example.com	1	C_IN	1	A	0	NOERROR	F	F	T	T	F	93.184.216.34	300	F
1672531210.234567	Dy5678efgh	192.168.1.100	52342	8.8.8.8	53	udp	0x5678	0.031	evil.com	1	C_IN	28	AAAA	3	NxDOMAIN	F	F	T	T	F	-	-	F
```

---

## 3. DNS 脚本事件

### 3.1 dns_request 事件

```zeek
event dns_request(c: connection, msg: dns_msg, query: string, qtype: count)
```

触发时机：DNS 请求解析完成后。

```zeek
# 检测异常 DNS 流量
event dns_request(c: connection, msg: dns_msg, query: string, qtype: count)
    {
    print fmt("[DNS] Query: %s TYPE=%s from %s",
              query, qtype, c$id$orig_h);
    }
```

### 3.2 dns_reply 事件

```zeek
event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count,
                rcode: count, answers: vector of string, TTLs: vector of count)
```

触发时机：DNS 响应解析完成后。

```zeek
# 分析 DNS 响应
event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count,
                rcode: count, answers: vector of string, TTLs: vector of count)
    {
    if (rcode == 0 && |answers| > 0) {
        print fmt("[DNS] %s -> %s", query, answers[0]);
    } else if (rcode == 3) {
        print fmt("[DNS] NXDOMAIN for %s", query);
    }
    }
```

### 3.3 dns_query 事件

```zeek
event dns_query(c: connection, msg: dns_msg, query: string,
                qtype: count, qclass: count)
```

触发时机：每个 DNS 查询记录解析时。

```zeek
# 追踪特定域名查询
event dns_query(c: connection, msg: dns_msg, query: string,
                qtype: count, qclass: count)
    {
    if (/malware|phishing|apt/i in query) {
        NOTICE([$note = DNS_SINKHOLE,
                $msg = fmt("Suspicious domain query: %s from %s",
                           query, c$id$orig_h),
                $conn = c]);
    }
    }
```

---

## 4. DNS 隧道检测

### 4.1 基于查询长度的检测

```zeek
# 检测异常长的子域名（DNS 隧道特征）
event dns_query(c: connection, msg: dns_msg, query: string,
                qtype: count, qclass: count)
    {
    # 提取子域名部分
    local parts = split_string(query, /\./);
    if (|parts| > 0) {
        local subdomain = parts[0];

        # 检测超长子域名
        if (|subdomain| > 50) {
            NOTICE([$note = DNS_TUNNEL,
                    $msg = fmt("Long subdomain detected: %s (%d chars) from %s",
                               subdomain, |subdomain|, c$id$orig_h),
                    $conn = c]);
        }
    }
    }
```

### 4.2 基于熵的检测

```zeek
# 计算字符串熵
function calculate_entropy(s: string): real {
    local freq: table[count] of count;
    local len = |s|;

    for (i in s) {
        freq[count(s[i])] += 1;
    }

    local entropy = 0.0;
    for (k in freq) {
        local p = (freq[k] * 1.0) / len;
        if (p > 0.0) {
            entropy -= p * log(p) / log(2.0);
        }
    }
    return entropy;
}

# 检测高熵子域名
event dns_query(c: connection, msg: dns_msg, query: string,
                qtype: count, qclass: count)
    {
    local parts = split_string(query, /\./);
    if (|parts| > 0) {
        local subdomain = parts[0];
        local entropy = calculate_entropy(subdomain);

        # DNS 隧道工具（如 dns2tcp）产生的子域名熵值较高
        if (entropy > 4.5 && |subdomain| > 20) {
            NOTICE([$note = DNS_TUNNEL,
                    $msg = fmt("High entropy subdomain: %s (entropy=%.2f) from %s",
                               subdomain, entropy, c$id$orig_h),
                    $conn = c]);
        }
    }
    }
```

### 4.3 DNS 隧道数据外传检测

```zeek
# 检测 DNS TXT 记录隧道
event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count,
                rcode: count, answers: vector of string, TTLs: vector of count)
    {
    if (qtype == 16 && rcode == 0 && |answers| > 0) {  # TXT
        for (answer in answers) {
            if (|answer| > 100) {
                NOTICE([$note = DNS_TUNNEL,
                        $msg = fmt("Large TXT record: %d bytes from %s to %s",
                                   |answer|, c$id$orig_h, query),
                        $conn = c]);
            }
        }
    }
    }
```

---

## 5. DNS 恶意域名检测

### 5.1 威胁情报匹配

```zeek
# 加载威胁情报
redef Intel::seed += {
    [$indicator = "malware-c2.example.com", $indicator_type = Intel::DOMAIN,
     $meta = [$desc = "Malware C2"]],
    [$indicator = "phishing-site.example.com", $indicator_type = Intel::DOMAIN,
     $meta = [$desc = "Phishing"]],
};
```

### 5.2 动态威胁检测

```zeek
# 监控快速生成域名 (DGA)
global domain_cache: table[string] of set[string];

event dns_query(c: connection, msg: dns_msg, query: string,
                qtype: count, qclass: count)
    {
    # 检测同客户端对大量不同域名的查询
    if (c$id$orig_h !in domain_cache) {
        domain_cache[c$id$orig_h] = set();
    }

    add domain_cache[c$id$orig_h][query];

    # 同一源在短时间内查询超过阈值
    local query_count = |domain_cache[c$id$orig_h]|;
    if (query_count > 100) {
        NOTICE([$note = DGA_DETECTED,
                $msg = fmt("Possible DGA: %s made %d DNS queries",
                           c$id$orig_h, query_count),
                $conn = c]);
    }
    }
```

### 5.3 DNS 重绑定检测

```zeek
# 检测 DNS 重绑定攻击特征
global dns_responses: table[string, count] of set[string];

event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count,
                rcode: count, answers: vector of string, TTLs: vector of count)
    {
    if (rcode == 0 && qtype == 1 && |answers| > 0) {
        local key = fmt("%s%s", c$id$orig_h, query);
        local answer_ip = answers[0];

        if (key in dns_responses) {
            # 检测同一域名返回不同 IP
            if (answer_ip !in dns_responses[key]) {
                NOTICE([$note = DNS_REBINDING,
                        $msg = fmt("DNS rebinding detected: %s returned %s (was %s)",
                                   query, answer_ip, dns_responses[key]),
                        $conn = c]);
            }
        } else {
            dns_responses[key] = set();
        }

        add dns_responses[key][answer_ip];
    }
    }
```

---

## 6. DNS 配置选项

### 6.1 主要配置项

```zeek
# 日志详细程度
redef DNS::disable_log_query = F;      # 禁用查询日志
redef DNS::disable_log_reply = F;       # 禁用响应日志
redef DNS::log_all_query_text = F;      # 记录所有查询文本

# 验证
redef DNS::validates_messages = F;      # 验证 DNS 消息签名

# 端口映射
redef DNS::default_ports = { 53/udp, 53/tcp };
```

### 6.2 DNS 端口配置

```zeek
# 添加 DNS over TCP 支持
redef DNS::default_ports += { 5353/udp };  # mDNS

# 启用 DNS 缓存
redef DNS::enable_dns_cache = T;
```

---

## 7. DNS 日志分析场景

### 7.1 C2 通信检测

```zeek
# 典型 C2 DNS 流量特征
# 1. 长查询间隔
# 2. 周期性查询
# 3. 异常域名结构

global c2_domains: set[string] = {
    "apt-c2.example.com",
    "backdoor-c2.example.net",
    "trojan-c2.example.org"
};

event dns_query(c: connection, msg: dns_msg, query: string,
                qtype: count, qclass: count)
    {
    if (query in c2_domains) {
        NOTICE([$note = C2_DETECTED,
                $msg = fmt("C2 domain contacted: %s from %s",
                           query, c$id$orig_h),
                $conn = c]);
    }
    }
```

### 7.2 数据泄露检测

```zeek
# 检测大量 DNS 查询（可能的数据外传）
global dns_query_count: table[addr] of count;

event dns_request(c: connection, msg: dns_msg, query: string,
                  qtype: count)
    {
    if (c$id$orig_h !in dns_query_count) {
        dns_query_count[c$id$orig_h] = 0;
    }

    dns_query_count[c$id$orig_h] += 1;

    # 超过阈值触发告警
    if (dns_query_count[c$id$orig_h] > 1000) {
        NOTICE([$note = DATA_EXFILTRATION,
                $msg = fmt("High DNS query rate from %s: %d queries",
                           c$id$orig_h, dns_query_count[c$id$orig_h]),
                $conn = c]);
    }
    }
```

---

## 8. DNS 与其他协议联动

### 8.1 HTTP DNS 关联分析

```zeek
# 关联 HTTP 主机名与 DNS 查询
global http_hosts: table[string] of string;  # uid -> hostname

event http_request(c: connection, method: string, original_URI: string,
                   unescaped_URI: string, version: string)
    {
    if (c$http?$host) {
        http_hosts[c$uid] = c$http$host;
    }
    }

event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count,
                rcode: count, answers: vector of string, TTLs: vector of count)
    {
    # 检查是否有 HTTP 连接使用同一域名
    for (uid in http_hosts) {
        if (http_hosts[uid] == query) {
            print fmt("[DNS-HTTP] DNS resolved %s -> %s for HTTP conn %s",
                     query, answers[0], uid);
        }
    }
    }
```

### 8.2 SSL 证书与 DNS 关联

```zeek
# 关联 SSL SNI 与 DNS 查询
global ssl_sni: table[string] of string;  # uid -> SNI

event ssl_extension(c: connection, name: string, value: string) {
    if (name == "server_name") {
        ssl_sni[c$uid] = value;
    }
}

event dns_reply(c: connection, msg: dns_msg, query: string, qtype: count,
                rcode: count, answers: vector of string, TTLs: vector of count)
    {
    # 检测 SSL SNI 与 DNS 不一致
    for (uid in ssl_sni) {
        if (ssl_sni[uid] != query && ssl_sni[uid] in query) {
            NOTICE([$note = WEIRD_SSL_SNI,
                    $msg = fmt("SSL SNI %s differs from DNS query %s",
                               ssl_sni[uid], query),
                    $conn = c]);
        }
    }
    }
```

---

## 9. 小结

本章介绍了 Zeek DNS 分析器的核心能力：

| 组件            | 说明                                       |
| --------------- | ------------------------------------------ |
| **DNS::Info**   | DNS 日志核心 record，包含查询/响应完整信息 |
| **dns_request** | DNS 请求事件                               |
| **dns_reply**   | DNS 响应事件，包含 answers 和 TTLs         |
| **dns_query**   | 单条查询记录事件                           |
| **qtype_name**  | 查询类型名称（A/AAAA/MX/TXT 等）           |

DNS 日志是威胁检测的重要数据源，可用于检测：

- DNS 隧道数据外传
- 恶意域名访问
- DGA（域名生成算法）
- DNS 重绑定攻击
- C2 通信

结合 HTTP、SSL 等协议日志，可以实现更精准的威胁狩猎。
