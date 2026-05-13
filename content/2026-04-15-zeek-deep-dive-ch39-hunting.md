---
title: "Zeek 深度探索 (三十九)：威胁狩猎"
date: 2026-04-15
tags:
  - zeek
  - series
  - threat-hunting
  - ioc
  - mitre
  - attck
  - hunting
  - detection
description: "深入解析 Zeek 威胁狩猎——日志分析、MITRE ATT&CK 映射、IOC 提取、狩猎查询示例、ZeekScript 自动化检测"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ... 38. [[2026-04-15-zeek-deep-dive-ch38-eve|第三十八章：EVE 格式]] 39. **第三十九章：威胁狩猎** 40. [[2026-04-15-zeek-deep-dive-ch40-siem|第四十章：SIEM 集成]]

---

## 1. 威胁狩猎概述

威胁狩猎（Threat Hunting）是**主动发现网络中潜在恶意行为**的过程，区别于传统的基于签名的检测，狩猎强调分析师的经验和假设驱动发现。

```
┌─────────────────────────────────────────────────────────────┐
│                   威胁狩猎流程                               │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   假设驱动                                                  │
│      │                                                      │
│      ▼                                                      │
│   ┌────────────────────────────────────────────────┐        │
│   │  1. 假设提出：APT29 使用 DNS C2                  │        │
│   └────────────────────────────────────────────────┘        │
│      │                                                      │
│      ▼                                                      │
│   ┌────────────────────────────────────────────────┐        │
│   │  2. 数据收集：DNS 日志、conn.log、ssl.log        │        │
│   └────────────────────────────────────────────────┘        │
│      │                                                      │
│      ▼                                                      │
│   ┌────────────────────────────────────────────────┐        │
│   │  3. 分析验证：长域名、DGA、TXT 记录查询           │        │
│   └────────────────────────────────────────────────┘        │
│      │                                                      │
│      ▼                                                      │
│   ┌────────────────────────────────────────────────┐        │
│   │  4. 发现：找到可疑域名 example-long-domain.com    │        │
│   └────────────────────────────────────────────────┘        │
│      │                                                      │
│      ▼                                                      │
│   报告 / 告警 / 新假设                                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Zeek 在威胁狩猎中的角色

Zeek 是威胁狩猎的**核心数据来源**，提供：

| 能力           | 说明                             | 狩猎价值                 |
| :------------- | :------------------------------- | :----------------------- |
| **应用层语义** | HTTP/DNS/TLS 等完整协议解析      | 发现命令与控制、数据泄露 |
| **连接上下文** | 完整会话记录、持续时间、字节统计 | 检测可疑通信模式         |
| **文件提取**   | 文件哈希、元数据、MIME 类型      | 发现恶意软件投递         |
| **告警框架**   | Notice 框架、自定义检测          | 自动化威胁识别           |
| **脚本扩展**   | ZeekScript 自定义分析逻辑        | 定制化狩猎场景           |

---

## 2. MITRE ATT&CK 映射

### 2.1 ATT&CK 框架概述

MITRE ATT&CK 是基于真实世界的**攻击行为知识库**，将攻击技术按战术（Tactics）和技术（Techniques）组织。

**主要战术**：

| 战术   | 说明       | 关联日志               |
| :----- | :--------- | :--------------------- |
| TA0043 | 敌对侦察   | conn.log, dns.log      |
| TA0001 | 初始访问   | smtp.log, http.log     |
| TA0002 | 执行       | process Creation, file |
| TA0003 | 持久化     | cron, services         |
| TA0004 | 权限提升   | sudo, suid             |
| TA0005 | 防御规避   | -                      |
| TA0006 | 凭证访问   | ssl.log, ssh.log       |
| TA0007 | 发现       | conn.log               |
| TA0008 | 横向移动   | conn.log, smb.log      |
| TA0009 | 收集       | http.log, smtp.log     |
| TA0010 | 外泄       | conn.log, http.log     |
| TA0011 | 命令与控制 | dns.log, http.log      |
| TA0040 | 影响       | ransomware 特征        |

### 2.2 Zeek 日志与 ATT&CK 映射

#### T1071 - 应用层协议命令与控制

```
┌─────────────────────────────────────────────────────────────┐
│  T1071: Application Layer Protocol                          │
│  └─ 使用 HTTP/HTTPS/DNS 进行 C2                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Zeek 日志: http.log, dns.log, ssl.log                      │
│                                                             │
│  检测点:                                                    │
│  ├── HTTP: 非标准端口、异常 User-Agent、长 URI              │
│  ├── DNS:  长域名、DGA、TXT 记录、异常 Query 类型            │
│  └── TLS:  异常 SNI、已知恶意证书、自签名证书               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

```zeek
# 检测非标准端口 HTTP 流量
event http_request(c: connection, method: string, URI: string,
                   original_URI: string, version: string) {
    # 非 80/443 端口的 HTTP
    if ( c$id$resp_p != 80/tcp && c$id$resp_p != 8080/tcp ) {
        NOTICE([$note=HTTP::Non_Standard_Port,
                $msg=fmt("HTTP on non-standard port: %s", c$id),
                $conn=c]);
    }
}
```

#### T1070 - 主机持久化指标

```
┌─────────────────────────────────────────────────────────────┐
│  T1070: Indicator Removal on Host                          │
│  └─ 清除日志、修改文件时间戳                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Zeek 日志: weird.log, notice.log                           │
│                                                             │
│  检测点:                                                    │
│  ├── 大量 weird 事件（可能日志清除前兆）                   │
│  └── notice.log 中的异常删除事件                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### T1046 - 网络服务扫描

```
┌─────────────────────────────────────────────────────────────┐
│  T1046: Network Service Scanning                           │
│  └─ 扫描发现内网服务                                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Zeek 日志: conn.log                                         │
│                                                             │
│  检测点:                                                    │
│  ├── 短时间内连接大量端口                                   │
│  ├── 连接失败率异常（S0/SYN_SENT 状态）                   │
│  └── 扫描同一子网的多个主机                                 │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

```zeek
# 检测网络扫描
event connection_state_remove(c: connection) {
    if ( c$orig$size == 0 && c$resp$size == 0 ) {
        # 空连接（可能是扫描探测）
        local count = ConnTable::get_connection_count(c$id$orig_h);
        if ( count > 100 ) {
            NOTICE([$note=NetworkScan,
                    $msg=fmt("Potential scan from %s", c$id$orig_h),
                    $src=c$id$orig_h]);
        }
    }
}
```

### 2.3 ATT&CK 狩猎查询矩阵

| ATT&CK ID | 技术     | 狩猎查询          | Zeek 日志 |
| :-------- | :------- | :---------------- | :-------- |
| T1071.004 | DNS C2   | `query长度 > 50`  | dns.log   |
| T1071.001 | HTTP C2  | `User-Agent 异常` | http.log  |
| T1090     | 代理通道 | `大量代理连接`    | conn.log  |
| T1046     | 服务扫描 | `连接端口数 > 50` | conn.log  |
| T1048     | 数据外泄 | `上传字节异常大`  | conn.log  |
| T1057     | 进程发现 | `WMI/SMB 调用`    | smb.log   |

---

## 3. IOC 提取

### 3.1 IOC 类型

IOC（Indicators of Compromise）是**可观测的威胁指标**：

| IOC 类型 | 示例                | Zeek 提取                     |
| :------- | :------------------ | :---------------------------- |
| IP 地址  | 恶意 C2 服务器      | `id.resp_h`                   |
| 域名     | DGA 域名、钓鱼域名  | `query` in dns.log            |
| URL      | 恶意下载链接        | `uri` in http.log             |
| 文件哈希 | 恶意软件 MD5/SHA256 | `md5` in files.log            |
| 证书指纹 | SHA1/JA3            | `client_cert_sha1` in ssl.log |
| 用户名   | 窃取的凭证          | `username` in ssh.log         |

### 3.2 自动 IOC 提取

```zeek
# /usr/local/zeek/share/zeek/site/ioc-extract.zeek

@load base/frameworks/logging
@load base/frameworks/notice

module IOC;

export {
    global extracted_iocs: table[string] of count;

    # 提取的 IOC 存储
    global extracted_domains: set[string] &writeable;
    global extracted_ips: set[string] &writeable;
    global extracted_hashes: set[string] &writeable;
    global extracted_urls: set[string] &writeable;
}

# =================== DNS IOC 提取 ===================
event dns_request(c: connection, query: string, qtype: count) {
    # 长域名（可能是 DGA）
    if ( |query| > 50 ) {
        add extracted_domains[query];
        NOTICE([$note=IOC::Domain,
                $msg=fmt("Long domain (possible DGA): %s", query),
                $identifier=query]);
    }

    # 异常 Query 类型
    if ( qtype == 15 && query != "" ) {
        add extracted_domains[query];
        NOTICE([$note=IOC::MX_Query,
                $msg=fmt("Suspicious MX query: %s", query),
                $identifier=query]);
    }
}

# =================== HTTP IOC 提取 ===================
event http_request(c: connection, method: string, uri: string,
                   original_URI: string, version: string) {
    # 可疑 URL 模式
    if ( /\.(exe|dll|bat|ps1|vbs|js|jar)$/ in uri ) {
        add extracted_urls[uri];
        NOTICE([$note=IOC::Suspicious_URL,
                $msg=fmt("Suspicious executable URL: %s", uri),
                $identifier=uri]);
    }
}

# =================== TLS IOC 提取 ===================
event ssl_server_certificate(c: connection, cert: string,
                              chain: bool, calculated_cs: string) {
    # 自签名证书
    if ( chain == F ) {
        NOTICE([$note=IOC::SelfSigned_Cert,
                $msg=fmt("Self-signed certificate: %s", c$id$resp_h),
                $identifier=c$id$resp_h]);
    }
}

# =================== 文件哈希提取 ===================
event file_hash(c: connection, fa: file_analysis, kind: string,
                hash: string) {
    if ( kind == "md5" || kind == "sha256" ) {
        add extracted_hashes[hash];
    }
}
```

### 3.3 已知恶意 IOC 匹配

```zeek
# /usr/local/zeek/share/zeek/site/ioc-match.zeek

@load base/frameworks/intel

# 加载威胁情报
redef Intel::seed_data += {
    # 恶意域名
    [$indicator="malware-c2.example.com",
     $indicator_type=Intel::DOMAIN,
     $meta=[$source="threat-feed", $confidence=Intel::HIGH]],

    # 恶意 IP
    [$indicator="192.0.2.100",
     $indicator_type=Intel::ADDR,
     $meta=[$source="threat-feed", $confidence=Intel::HIGH]],

    # 恶意文件哈希
    [$indicator="d41d8cd98f00b204e9800998ecf8427e",
     $indicator_type=Intel::FILE_HASH,
     $meta=[$source="threat-feed", $confidence=Intel::HIGH]],
};

# 命中时触发告警
event intel_hit(item: Intel::Item, id: Conn::Info, data: string) {
    NOTICE([$note=Intel::match,
            $msg=fmt("IOC match: %s - %s", item$indicator, item$indicator_type),
            $conn=id,
            $identifier=item$indicator]);
}
```

### 3.4 输出 IOC 提取结果

```zeek
# 将提取的 IOC 输出到专用日志
event zeek_init() {
    Log::create_stream(IOC::LOG, [$path="iocs"]);

    Log::add_filter(IOC::LOG, [
        $name="csv",
        $path="iocs",
        $writer=Log::ASCII
    ]);
}

# 定期输出 IOC 统计
event ioc_stats() {
    print fmt("Extracted IOCs:");
    print fmt("  Domains: %d", |extracted_domains|);
    print fmt("  IPs: %d", |extracted_ips|);
    print fmt("  Hashes: %d", |extracted_hashes|);
    print fmt("  URLs: %d", |extracted_urls|);
}

# 每小时统计
schedule 1hr { ioc_stats() };
```

---

## 4. 狩猎查询示例

### 4.1 DNS 隧道检测

```bash
# 检测大量 TXT 记录查询（DNS 隧道特征）
zeek-cut ts uid query qtype answers < dns.log | \
    awk '$3 == "TXT" {print}' | head

# 检测长域名（潜在 DGA）
zeek-cut query < dns.log | awk 'length > 50 {print}'

# 检测异常 query 类型
zeek-cut query qtype < dns.log | awk '$2 != "A" && $2 != "AAAA" && $2 != "CNAME" && $2 != "MX" && $2 != "NS" {print}'
```

```zeek
# ZeekScript DNS 隧道检测
event dns_request(c: connection, query: string, qtype: count) {
    # 检测 TXT 记录查询
    if ( qtype == 16 ) {
        local txt_count = 0;
        for ( answer in c$dns$answers ) {
            if ( |answer$query| > 100 ) {
                NOTICE([$note=DNS_Tunneling,
                        $msg=fmt("Possible DNS tunneling: %s", query),
                        $conn=c]);
            }
        }
    }
}
```

### 4.2 HTTP C2 检测

```bash
# 检测非常长 User-Agent
zeek-cut user_agent < http.log | awk 'length > 100 {print}'

# 检测非标准端口 HTTP
zeek-cut id.resp_p host uri < http.log | awk '$1 != 80 && $1 != 8080 && $1 != 443 {print}'

# 检测异常 HTTP 方法
zeek-cut method uri < http.log | awk '$1 != "GET" && $1 != "POST" && $1 != "PUT" && $1 != "DELETE" {print}'
```

```zeek
# ZeekScript HTTP C2 检测
event http_request(c: connection, method: string, uri: string,
                   original_URI: string, version: string) {
    # 检测长 URI（可能的 C2 通信）
    if ( |uri| > 500 ) {
        NOTICE([$note=Suspicious_HTTP_URI,
                $msg=fmt("Long URI detected: %d bytes from %s", |uri|, c$id$orig_h),
                $conn=c]);
    }

    # 检测异常 User-Agent
    if ( c?$http && c$http?$user_agent ) {
        local ua = c$http$user_agent;
        # 常见攻击工具 User-Agent
        if ( /python-requests|Masscan|nmap|wget|curl.*golang/ in ua ) {
            NOTICE([$note=HTTP_Tool_UA,
                    $msg=fmt("Tool User-Agent: %s", ua),
                    $conn=c]);
        }
    }
}
```

### 4.3 横向移动检测

```bash
# 检测同一源 IP 连接多个内网主机（横向移动特征）
zeek-cut id.orig_h id.resp_h id.resp_p < conn.log | \
    awk '{print $1, $3}' | sort | uniq -c | awk '$1 > 50 {print}'

# 检测 SMB 异常
zeek-cut id.orig_h id.resp_h service < conn.log | \
    awk '$3 == "smb" {print}' | head

# 检测 SSH 暴力破解
zeek-cut id.orig_h id.resp_h auth_success < ssh.log | \
    awk '$3 == "F" {print}' | sort | uniq -c | awk '$1 > 10 {print}'
```

```zeek
# ZeekScript 横向移动检测
event connection_state_remove(c: connection) {
    # 检测同一源 IP 连接多个内网服务
    if ( c$orig$size > 0 ) {
        local orig_ip = c$id$orig_h;
        local target_ips = ConnTable::get_target_ips(orig_ip);

        # 短时间内连接超过 10 个不同目标 IP
        if ( |target_ips| > 10 ) {
            NOTICE([$note=Lateral_Movement,
                    $msg=fmt("Possible lateral movement from %s to %d hosts",
                             orig_ip, |target_ips|),
                    $src=orig_ip]);
        }
    }
}
```

### 4.4 数据外泄检测

```bash
# 检测大文件外发
zeek-cut id.orig_h id.resp_h orig_bytes < conn.log | \
    awk '$3 > 10000000 {print}'  # > 10MB

# 检测 HTTP POST 上传大文件
zeek-cut id.orig_h id.resp_h method uri resp_fuids < http.log | \
    awk '$2 == "POST" && $4 != "" {print}'

# 检测可疑 DNS 查询（数据外泄）
zeek-cut query answers < dns.log | awk '/[A-Za-z0-9]{50,}/ {print}'
```

```zeek
# ZeekScript 数据外泄检测
event file_over_new_connection(f: fa_file, c: connection, meta: fa_metadata) {
    # 检测大文件提取
    if ( meta$size > 10MB ) {
        NOTICE([$note=Large_File_Transfer,
                $msg=fmt("Large file detected: %s (%s) from %s",
                         f$info$filename,
                         fmt("%d bytes", meta$size),
                         c$id$orig_h),
                $conn=c]);
    }

    # 检测可疑 MIME 类型
    if ( /\.exe$|\.dll$|\.vbs$|\.ps1$/ in f$info$filename ) {
        NOTICE([$note=Suspicious_File_Type,
                $msg=fmt("Executable file: %s", f$info$filename),
                $conn=c]);
    }
}
```

### 4.5 认证异常检测

```bash
# 检测 SSH 暴力破解
zeek-cut id.orig_h id.resp_h auth_success login < ssh.log | \
    awk '$3 == "F" {print}' | sort | uniq -c | sort -rn | head

# 检测 RDP 暴力破解
zeek-cut id.orig_h id.resp_h logged_in < rdp.log | \
    awk '$3 == "F" {print}' | sort | uniq -c | head

# 检测 SQL 注入特征
zeek-cut uri < http.log | grep -E "union.*select|exec\(|substring\("
```

---

## 5. ZeekScript 自动化检测

### 5.1 检测框架

```zeek
# /usr/local/zeek/share/zeek/site/hunting-framework.zeek

@load base/frameworks/logging
@load base/frameworks/notice

module Hunting;

export {
    # 狩猎假设状态
    global hypotheses: table[string] of hypothesis_state;

    type hypothesis_state: record {
        name: string;
        description: string;
        created: time;
        hits: count;
        evidence: vector of string;
    };

    # 创建假设
    global create_hypothesis: function(name: string, desc: string): bool;

    # 添加证据
    global add_evidence: function(hypothesis: string, evidence: string): bool;

    # 报告假设
    global report_hypothesis: function(hypothesis: string): hypothesis_state;
}

function create_hypothesis(name: string, desc: string): bool {
    hypotheses[name] = [$name=name, $description=desc,
                        $created=current_time(), $hits=0, $evidence=vector()];
    return T;
}

function add_evidence(hypothesis: string, evidence: string): bool {
    if ( hypothesis !in hypotheses ) {
        return F;
    }
    hypotheses[hypothesis]$evidence += evidence;
    hypotheses[hypothesis]$hits += 1;
    return T;
}
```

### 5.2 实时检测脚本

```zeek
# /usr/local/zeek/share/zeek/site/detect-framework.zeek

@load base/frameworks/notice
@load base/frameworks/cluster

module Detect;

export {
    # 检测结果
    global detections: table[string] of detection_result;

    type detection_state: enum {
        Suspicious,
        Confirmed,
        Cleared
    };

    type detection_result: record {
        rule_id: string;
        rule_name: string;
        state: detection_state;
        timestamp: time;
        conn: connection;
        details: string;
    };
}

# =================== 检测规则 ===================

# DGA 域名检测
event dns_request(c: connection, query: string, qtype: count) {
    # 简单 DGA 检测：域名长度 > 30 且包含数字
    if ( |query| > 30 && /[0-9]{3,}/ in query ) {
        NOTICE([$note=SUSPICIOUS_DOMAIN,
                $msg=fmt("Possible DGA domain: %s", query),
                $conn=c]);
    }
}

# 非浏览器 User-Agent
event http_request(c: connection, method: string, uri: string,
                   original_URI: string, version: string) {
    if ( c?$http && c$http?$user_agent ) {
        local ua = c$http$user_agent;

        # 常见攻击工具
        if ( /python-requests|Masscan|Scan|Metasploit|nmap/ in ua ) {
            NOTICE([$note=HTTP_Tool_Detected,
                    $msg=fmt("Tool User-Agent: %s", ua),
                    $conn=c]);
        }
    }
}

# 内部 IP 直连外部（数据外泄风险）
event connection_established(c: connection) {
    if ( c?$orig && c$orig$laddr == 10.0.0.0/8 ) {
        # 内部地址直连非标准端口
        if ( c$id$resp_p > 1024/tcp && c$id$resp_p != 3306/tcp &&
             c$id$resp_p != 5432/tcp ) {
            NOTICE([$note=Internal_Connection,
                    $msg=fmt("Internal IP %s connecting to %s:%s",
                             c$id$orig_h, c$id$resp_h, c$id$resp_p),
                    $conn=c]);
        }
    }
}
```

---

## 6. 狩猎工作流

### 6.1 假设驱动狩猎

```
1. 提出假设
   └─ "攻击者使用 DNS 隧道进行数据外泄"

2. 收集相关日志
   └─ dns.log: TXT/NULL query, 长域名
   └─ conn.log: 持续连接, 异常流量模式

3. 分析验证
   └─ 查询分布: 大部分 DNS 查询是否很短？
   └─ 流量时间: 是否在非工作时间有大量 DNS？
   └─ 响应大小: DNS 响应是否携带数据？

4. 迭代深入
   └─ 如果发现可疑 → 提取 IOC → 生成告警
   └─ 如果未发现 → 修改假设 → 继续狩猎
```

### 6.2 数据驱动狩猎

```
1. 异常检测
   └─ 统计建模: 什么是"正常"？
   └─ 异常识别: 与正常偏差最大的事件

2. 模式匹配
   └─ MITRE ATT&CK 技术特征
   └─ YARA 规则应用于提取文件

3. 关联分析
   └─ 跨日志源关联: HTTP + DNS + Conn
   └─ 时间序列分析: 事件前后关系
```

### 6.3 狩猎工具链

| 工具            | 用途         | Zeek 配合    |
| :-------------- | :----------- | :----------- |
| `zeek-cut`      | 日志字段提取 | 快速查询     |
| `jq`            | JSON 处理    | EVE 日志分析 |
| `Elasticsearch` | 日志存储检索 | 长期分析     |
| `Grafana`       | 可视化       | 态势感知     |
| `MISP`          | 威胁情报     | IOC 匹配     |
| `YARA`          | 规则匹配     | 恶意软件分析 |

---

## 7. 高级狩猎场景

### 7.1 DNS 隧道检测

```zeek
# /usr/local/zeek/share/zeek/site/dns-tunnel.zeek

@load base/frameworks/notice

module DNSTunnel;

export {
    global txt_queries: table[string] of count &writeable;
    global long_queries: table[string] of count &writeable;
}

event dns_request(c: connection, query: string, qtype: count) {
    # 检测 TXT 记录查询（DNS 隧道常用）
    if ( qtype == 16 ) {
        txt_queries[c$id$orig_h] = get_or_default(txt_queries, c$id$orig_h, 0) + 1;

        if ( txt_queries[c$id$orig_h] > 10 ) {
            NOTICE([$note=DNS_Tunnel_Suspected,
                    $msg=fmt("Excessive TXT queries from %s: %d",
                             c$id$orig_h, txt_queries[c$id$orig_h]),
                    $src=c$id$orig_h]);
        }
    }

    # 检测长域名
    if ( |query| > 50 ) {
        long_queries[query] = get_or_default(long_queries, query, 0) + 1;
    }
}

event dns_END_REQUEST(c: connection, msg: dns_msg) {
    # 检测异常大 DNS 响应
    if ( msg$size > 512 ) {
        NOTICE([$note=DNS_Large_Response,
                $msg=fmt("Large DNS response (%d bytes) for %s",
                         msg$size, c$query),
                $conn=c]);
    }
}
```

### 7.2 Cobalt Strike C2 检测

```zeek
# /usr/local/zeek/share/zeek/site/cobalt-strike.zeek

@load base/frameworks/notice
@load base/frameworks/intel

# Cobalt Strike 特征检测
event http_request(c: connection, method: string, uri: string,
                   original_URI: string, version: string) {
    # Cobalt Strike 默认路径
    local cs_paths = set(
        "/visit", "/api/", "/__u", "/pixel", "/form", "/go/get", "/news",
        "/cni/skin", "/skin", "/cm", "/北区"
    );

    if ( uri in cs_paths ) {
        NOTICE([$note=Possible_CobaltStrike,
                $msg=fmt("Cobalt Strike path detected: %s from %s",
                         uri, c$id$orig_h),
                $conn=c]);
    }
}

event http_reply(c: connection, status_code: string,
                 reason_phrase: string) {
    # Cobalt Strike 状态码
    if ( status_code == "200" && c?$http ) {
        local headers = c$http$host;

        # 检测 JARM 指纹（需要 SSL 分析）
        if ( c?$ssl && c$ssl?$server_name ) {
            # 已知恶意 JARM
            local known_cs_jarm = set(
                "1dead30f1ded1dead30f1ded1dead30f1dead30f1dead30f1dead30f1dead0",
                "2dead30f1ded1dead30f1ded1dead30f1dead30f1dead30f1dead30f1dead0"
            );
        }
    }
}

# JA3 指纹检测
event ssl_server_hello(c: connection, version: string,
                       cipher: string, ja3: string) {
    # Cobalt Strike 默认 JA3
    local cs_ja3 = set(
        "4d7a28d6f2263b1d6c1c3c9b4d3d2e1",  # 示例
        "5c2d3b7a1f4c8e2b9d5a6f1e3c2d4b8"   # 示例
    );

    if ( ja3 in cs_ja3 ) {
        NOTICE([$note=Possible_CobaltStrike_JA3,
                $msg=fmt("Cobalt Strike JA3 detected: %s", ja3),
                $conn=c]);
    }
}
```

### 7.3 供应链攻击检测

```zeek
# /usr/local/zeek/share/zeek/site/supply-chain.zeek

@load base/frameworks/notice

# 检测软件更新通道异常
event http_request(c: connection, method: string, uri: string,
                   original_URI: string, version: string) {
    # 常见软件更新域名
    local update_domains = set(
        "update.microsoft.com",
        "swscan.apple.com",
        "chrome-installer.google.com",
        "packages.microsoft.com"
    );

    if ( c?$http && c$http?$host ) {
        local host = c$http$host;

        # 检测非官方更新源
        if ( host !in update_domains ) {
            # 检查是否为软件更新模式
            if ( /\/update\/|\/install\/|\/download\// in uri ) {
                NOTICE([$note=Suspicious_Update,
                        $msg=fmt("Possible software update from non-standard source: %s", host),
                        $conn=c]);
            }
        }
    }
}
```

---

## 8. 狩猎报告模板

```markdown
# 威胁狩猎报告

## 狩猎假设

[假设描述]

## 数据源

- conn.log
- dns.log
- http.log
- ssl.log

## 分析方法

1. [方法1]
2. [方法2]
3. [方法3]

## 发现

### IOC

| 类型   | 值     | 首次发现时间     |
| :----- | :----- | :--------------- |
| Domain | xxxxxx | 2026-04-15 10:30 |
| IP     | xxxxxx | 2026-04-15 10:35 |

### ATT&CK 映射

| Technique | 描述   | 置信度 |
| :-------- | :----- | :----- |
| T1071.004 | DNS C2 | High   |

## 结论

[结论描述]

## 建议

[缓解措施]
```

---

## 总结

威胁狩猎是利用 Zeek 日志进行**主动发现恶意行为**的关键能力：

1. **ATT&CK 映射**：将 Zeek 日志事件映射到 MITRE ATT&CK 技术，形成结构化狩猎
2. **IOC 提取**：自动化提取域名、IP、哈希、URL 等威胁指标
3. **ZeekScript 自动化**：通过脚本实现实时检测规则，减少人工分析负担
4. **假设驱动**：从假设出发，结合数据验证，是高效狩猎的核心方法
