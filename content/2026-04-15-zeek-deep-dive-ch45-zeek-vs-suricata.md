---
title: "Zeek 深度探索 Ch45：Zeek vs Suricata 对比分析"
date: 2026-04-15
tags: [zeek, series, suricata, comparison]
description: "Zeek 与 Suricata 深度对比：架构设计、检测能力、性能、日志格式、部署场景"
---

# Zeek 深度探索 Ch45：Zeek vs Suricata 对比分析

## 概述

Zeek和Suricata是网络安全的两个重要开源工具，分别代表了网络监控和网络入侵检测的两个方向。理解两者的差异和互补性对于构建完整的安全体系至关重要。本章从架构设计、检测能力、性能特征、部署场景等多个维度进行深入对比分析。

## 架构设计对比

### Zeek架构

Zeek采用基于事件驱动的架构，将网络流量转换为高层语义事件：

```
┌─────────────────────────────────────────────────────────┐
│                    Zeek 架构                            │
├─────────────────────────────────────────────────────────┤
│  Packet Input  →  Event Engine  →  Event Pool          │
│                          ↓                              │
│                   Script Interpreter                    │
│                          ↓                              │
│         ┌──────────────────────────────┐              │
│         │     Log Layer (多格式输出)     │              │
│         └──────────────────────────────┘              │
│                          ↓                              │
│         ┌──────────────────────────────┐              │
│         │   JSON/TSV/ASCII/Elasticsearch │             │
│         └──────────────────────────────┘              │
└─────────────────────────────────────────────────────────┘
```

核心特性：

- **事件驱动**：所有网络行为都转换为事件，脚本可订阅处理
- **状态管理**：内置连接状态跟踪，支持复杂会话分析
- **协议解析**：30+应用层协议解析器，输出结构化日志
- **脚本语言**：自定义Zeek脚本语言，支持复杂逻辑

```zeek
# Zeek事件示例
event connection_established(c: connection) {
    Log::write(Conn::LOG, c$conn);
}

event http_request(c: connection, method: string, original_uri: string) {
    Log::write(HTTP::LOG, [
        $ts=c$start_time,
        $uid=c$uid,
        $method=method,
        $uri=original_uri
    ]);
}
```

### Suricata架构

Suricata采用多线程流水线架构，融合了IDS/IPS/NSM功能：

```
┌─────────────────────────────────────────────────────────┐
│                   Suricata 架构                         │
├─────────────────────────────────────────────────────────┤
│  Packet Capture  →  Decode  →  Stream  →  Detect        │
│       ↓                                    ↓            │
│  Workers (多线程)                    Rules Engine       │
│       ↓                                    ↓            │
│  App-Layer Parsers                Alert/Log Output      │
└─────────────────────────────────────────────────────────┘
```

核心特性：

- **多线程并行**：利用多核处理器，支持自动负载均衡
- **兼容Snort规则**：支持Suricata特定和Snort规则语法
- **内置ID/IP/NSM**：一台设备完成多种安全功能
- **自动协议检测**：基于芦oT (HTP)库的HTTP解析

```yaml
# Suricata规则示例
alert http $HOME_NET any -> $EXTERNAL_NET any \
(msg:"SQL Injection Attempt"; \
pcre:"/(union|select|insert|update|delete).*from/i"; \
sid:1000001; rev:1;)
```

## 检测能力对比

### 签名检测

| 特性     | Zeek           | Suricata                  |
| -------- | -------------- | ------------------------- |
| 规则格式 | Zeek脚本自定义 | Snort/Suricata规则        |
| 规则数量 | 依赖脚本实现   | 数十万预置规则            |
| 规则更新 | 社区活跃度较低 | OISF/Emerging Threats维护 |
| 规则编写 | 需要编程能力   | 规则语言相对简单          |

```zeek
# Zeek实现类似Suricata规则的检测
event http_request(c: connection, method: string, uri: string) {
    if (/\b(unix|select|insert|update|delete)\b/i in uri) {
        NOTICE([
            $msg="SQL Injection Attempt",
            $src=c$id$orig_h,
            $dst=c$id$resp_h,
            $identifier=generate_id()
        ]);
    }
}
```

```yaml
# Suricata Equivalent
alert http any any -> any any \
(msg:"SQL Injection Attempt"; \
content:"union"; nocase; http.uri; \
content:"select"; nocase; http.uri; \
sid:1000001; rev:1;)
```

### 异常检测

Zeek在异常检测方面具有显著优势：

```zeek
# Zeek异常检测示例：检测Beaconing行为
module BeaconDetect;

export {
    global beacon_interval: interval = 5mins;
    global threshold: count = 10;
}

global connection_times: table[addr,addr] of vector of time;

event connection_state_remove(c: connection, reason: string) {
    local key = (c$id$orig_h, c$id$resp_h);

    if (c$state == OUTPUT) {
        if (key in connection_times) {
            connection_times[key] += c$start_time;
        } else {
            connection_times[key] = vector(c$start_time);
        }

        # 检查时间间隔一致性
        if (|connection_times[key]| >= threshold) {
            local intervals = vector();
            for (i in connection_times[key][1:]) {
                intervals += connection_times[key][i] - connection_times[key][i-1];
            }

            local avg = calc_average(intervals);
            if (std_dev(intervals) < 10secs) {
                NOTICE([$msg="Potential Beacon Detected",
                       $src=c$id$orig_h, $dst=c$id$resp_h]);
            }
        }
    }
}
```

Suricata的异常检测主要依赖：

- **引擎检测**：异常协议特征
- **阈值模块**：基于计数的检测
- **app-layer协议异常**：HTTP、DNS等协议层异常

```yaml
# Suricata阈值配置
rate_filter:
  gen_id: 1, sig_id: 2001219, track: src_ip, count: 100, seconds: 60, new_action: drop, timeout: 10
```

### 协议解析

Zeek的优势在于深度协议分析和结构化日志输出：

```zeek
# Zeek输出示例：完整的协议解析日志
# conn.log
# fields: ts, uid, id.orig_h, id.orig_p, id.resp_h, id.resp_p, proto, service, duration, orig_bytes, resp_bytes, conn_state
# 2024-01-15 10:23:45.123    CFGSg1V1aJ3    192.168.1.100    52341    8.8.8.8    53    udp    dns    0.023    42    98    OK

# dns.log - 更详细的DNS分析
# fields: ts, uid, id.orig_h, id.orig_p, id.resp_h, id.resp_p, proto, trans_id, query, qclass, qtype, rcode, answers, TTLs
# 2024-01-15 10:23:45.100    CFGSg1V1aJ3    192.168.1.100    52341    8.8.8.8    53    udp    12345    evil.com    C_IN    A    NOERROR    10.0.0.1    300
```

Suricata的Eve日志也提供丰富的协议信息：

```json
{
  "timestamp": "2024-01-15T10:23:45.100",
  "event_type": "dns",
  "src_ip": "192.168.1.100",
  "src_port": 52341,
  "dest_ip": "8.8.8.8",
  "dest_port": 53,
  "dns": {
    "query": "evil.com",
    "type": "query",
    "id": 12345,
    "answers": ["10.0.0.1"]
  }
}
```

## 性能对比

### 处理能力

| 指标       | Zeek           | Suricata   |
| ---------- | -------------- | ---------- |
| 单线程处理 | 较高           | 中等       |
| 多核扩展   | 需要集群       | 自动多线程 |
| 内存占用   | 较高(状态维护) | 较低       |
| pcap处理   | 极快           | 快         |
| 实时处理   | 依赖硬件       | 依赖硬件   |

### 资源消耗对比

```bash
# Zeek资源监控
/usr/local/zeek/bin/zeekctl top

# 示例输出
Node             Host        ProcId    PID     VSize    RSS    Cnt    Strs   Done
zeek              localhost   manager   12345   2.1GB   1.8GB   1      320    -
zeek              localhost   proxy     12346   1.8GB   1.5GB   1      280    -
zeek              localhost   worker-1  12347   2.3GB   2.0GB   2      450    1234567
zeek              localhost   worker-2  12348   2.3GB   2.0GB   2      450    1234568
```

```bash
# Suricata资源监控
suricata -i eth0 --stats

# 示例输出
counter: capture.kernel_packets    = 1234567890
counter: capture.kernel_drops     = 12345
counter: detect.alert              = 567890
counter: stream.memuse             = 134217728
counter: stream.ssn_memuse         = 67108864
```

### 优化策略

```bash
# Zeek优化配置
# zeekctl.cfg
maxworkerreadsize=10000000
worker_cpus=4
proxy_cpus=2

# cluster.ini
[worker-1]
type=worker
host=localhost
interface=eth0
lb_procs=4
pin_cpus=0,1,2,3
```

```bash
# Suricata优化配置
# suricata.yaml
runmode: workers
worker-cpu-affinity: [0, 1, 2, 3]

stream:
  memcap: 256mb
  max-sessions: 262144
  prealloc-sessions: 131072

detect:
  profile: high
  sgh-mpm-context: auto
  spm-allocator: huge
```

## 日志输出对比

### Zeek日志类型

```bash
# 生成的日志文件列表
ls /var/log/zeek/
# conn.log        - 连接日志
# dns.log         - DNS查询日志
# http.log        - HTTP请求日志
# ssl.log         - SSL/TLS握手日志
# files.log       - 文件传输日志
# smtp.log        - SMTP邮件日志
# ssh.log         - SSH连接日志
# radius.log      - RADIUS认证日志
# openflow.log    - OpenFlow日志
# intel.log       - 威胁情报命中日志
# notice.log      - 告警日志
```

### Suricata日志类型

```bash
# 生成的日志文件列表 (Eve JSON格式)
# eve.json        - 所有事件的JSON汇总
# stats.log       - 统计信息
# alert-debug.log - 告警调试
# files-json.log  - 文件信息
```

### 日志格式对比

```bash
# Zeek TSV格式
# conn.log
ts	uid	id.orig_h	id.orig_p	id.resp_h	id.resp_p	proto	service	duration	orig_bytes	resp_bytes	conn_state
1705315425.123456	CHbVfs2kK7J	192.168.1.100	52341	93.184.216.34	443	tcp	https	1.234	1234	5678	SF

# Suricata JSON格式
# eve.json
{
  "timestamp": "2024-01-15T10:23:45.123",
  "event_type": "conn",
  "src_ip": "192.168.1.100",
  "src_port": 52341,
  "dest_ip": "93.184.216.34",
  "dest_port": 443,
  "proto": "TCP",
  "app_proto": "http"
}
```

## 部署场景对比

### Zeek适用场景

1. **深度网络分析**：需要完整网络流量可视化的场景
2. **威胁狩猎**：基于行为异常的高级威胁检测
3. **网络取证**：详细的会话记录用于事后分析
4. **协议研究**：新协议或自定义协议的深度分析
5. **安全运营中心**：需要结构化日志进行关联分析

```bash
# Zeek典型部署：被动网络监控
zeek -i eth0 -C 0

# 部署为分布式集群
# manager + proxy + worker 架构
# 使用ZeekControl管理
zeekctl deploy
```

### Suricata适用场景

1. **边界防护**：网络边界入侵检测
2. **实时告警**：基于签名的快速威胁检测
3. **IPS部署**：inline模式阻断恶意流量
4. **规则驱动检测**：依赖公开威胁情报规则
5. **性能敏感**：需要高性能多核处理

```bash
# Suricata IDS模式
suricata -c /etc/suricata/suricata.yaml -i eth0 --init-errors-fatal

# Suricata IPS模式 (NFQueue)
suricata -c /etc/suricata/suricata.yaml -q 0

# 规则更新
suricata-update
suricatasc -c ruleset-update
```

## 协同使用策略

### 架构设计

最佳实践是将两者结合，形成完整的网络安全监控体系：

```
                    ┌──────────────┐
                    │   Network    │
                    │   Tap/Span   │
                    └──────┬───────┘
                           │
              ┌────────────┴────────────┐
              │                         │
        ┌─────▼─────┐             ┌──────▼──────┐
        │   Zeek    │             │  Suricata   │
        │ (Monitor) │             │   (IDS/IPS) │
        └─────┬─────┘             └──────┬──────┘
              │                         │
              │                         │
        ┌─────▼─────┐             ┌──────▼──────┐
        │  Log      │             │   Alert     │
        │  Storage  │             │   Log       │
        │ (ELK)     │             │   (SIEM)    │
        └───────────┘             └─────────────┘
```

### 数据共享

```bash
# Zeek日志输出到Suricata
# 使用Suricata的JSON日志输入

# Zeek配置JSON输出
echo "@load policy/tuning/json-logs.zeek" >> /opt/zeek/share/zeek/site/local.zeek

# Suricata读取Zeek日志作为输入
# suricata.yaml
inputs:
  - file: /var/log/zeek/eve.json
    type: json_file
```

### 告警关联

```zeek
# Zeek脚本：消费Suricata告警
# suricata-alerts.zeek
module SuricataAlerts;

export {
    global alert_log: Log::Stream;
}

type SuricataAlert: record {
    ts: time;
    src_ip: addr;
    src_port: port;
    dst_ip: addr;
    dst_port: port;
    signature: string;
    category: string;
};

event file_incomplete(f: fa_file, reason: string) {
    # 检测到文件传输完成
    local info: SuricataAlert;
    # 与Suricata告警进行关联
}
```

```yaml
# Suricata配置：将Zeek数据纳入检测
# suricata.yaml
outputs:
  - eve-log:
      enabled: yes
      filetype: regular
      filename: eve-zeek.json
      types:
        - alert
        - http
        - dns
        - tls
```

## 规则转换

### Suricata规则转换为Zeek脚本

```yaml
# Suricata规则
alert http $HOME_NET any -> $EXTERNAL_NET any \
(msg:"SQL Injection Attempt"; \
content:"union"; http.uri; \
pcre:"/union\s+select/i"; \
sid:1000001; rev:1;)
```

```zeek
# 对应Zeek脚本
event http_request(c: connection, method: string,
                   original_uri: string, version: string) {

    local uri_lower = to_lower(original_uri);

    # 检测SQL注入特征
    if (/\bunion\s+select\b/i in uri_lower) {
        NOTICE([
            $msg="SQL Injection Attempt",
            $src=c$id$orig_h,
            $dst=c$id$resp_h,
            $p=fmt("URI: %s", original_uri),
            $identifier=generate_id()
        ]);
    }
}
```

### Zeek脚本转换为Suricata规则

```zeek
# Zeek检测SSH暴力破解
event ssh_auth_successful(c: connection, auth_method: string) {
    if (c$id$resp_h in suspicious_ssh_servers) {
        NOTICE([$msg="SSH Login to Suspicious Server",
               $src=c$id$orig_h,
               $dst=c$id$resp_h]);
    }
}
```

```yaml
# 对应Suricata规则
alert ssh $HOME_NET any -> $EXTERNAL_NET 22 \
(msg:"SSH Login to Suspicious Server"; \
flow:established,to_server; \
sid:1000002; rev:1;)
```

## 配置管理对比

### Zeek配置

```bash
# Zeek主配置
# /opt/zeek/etc/zeekctl.cfg
mailhost = smtp.example.com
mailfrom = zeek@example.com
mailto = security@example.com
LogDir = /var/log/zeek
SpoolDir = /var/spool/zeek
```

```bash
# local.zeek - 主脚本配置
@load base/frameworks/notice
@load base/protocols/http
@load base/protocols/dns
@load base/protocols/ssl

redef Site::local_nets = { 192.168.0.0/16, 10.0.0.0/8 };
redef Intel::do_existing = T;
redef Notice::emailed_types += { SQL_INJECTION, BEACON_DETECTED };
```

### Suricata配置

```yaml
# suricata.yaml
%YAML 1.1
---
vars:
  address-groups:
    HOME_NET: "[192.168.0.0/16,10.0.0.0/8]"
    EXTERNAL_NET: "!$HOME_NET"
  port-groups:
    HTTP_PORTS: "80,443,8080,8443"

engine-analysis:
  rules-fast-pattern: yes

app-layer:
  protocols:
    http:
      enabled: yes
      detection-ports:
        dp: [80, 443, 8080, 8443]
```

## 维护成本对比

| 维度     | Zeek           | Suricata                             |
| -------- | -------------- | ------------------------------------ |
| 学习曲线 | 陡峭(脚本语言) | 平缓(规则语法)                       |
| 社区规模 | 较小但专注     | 较大活跃                             |
| 文档质量 | 优秀           | 良好                                 |
| 商业支持 | Corelight      | Open Information Security Foundation |
| 更新频率 | 稳定迭代       | 频繁更新                             |

## 总结

Zeek和Suricata代表了网络安全监控的两个不同哲学：

- **Zeek**是一个深入的网络流量分析平台，擅长深度协议解析、行为分析和取证分析。其脚本语言提供了极大的灵活性，但需要编程能力。

- **Suricata**是一个高性能的入侵检测系统，擅长基于签名的实时检测和边界防护。其规则系统简单易用，社区活跃度高。

最佳实践是**结合使用两者**：使用Suricata进行边界实时检测和阻断，使用Zeek进行深度流量分析和威胁狩猎。这种组合可以充分发挥各自优势，构建全面的网络安全监控体系。

选择建议：

- 预算有限且需要快速部署：优先考虑Suricata
- 需要深度分析和取证能力：优先考虑Zeek
- 关键基础设施需要全面监控：两者结合使用
