---
title: "Zeek 深度探索 Ch44：Zeek 与 SIEM 及威胁情报平台集成"
date: 2026-04-15
tags: [zeek, series, siem, threat-intelligence]
description: "Zeek 与 SIEM 集成：Elasticsearch/Splunk/QRadar、MISP 威胁情报、自动化响应"
---

# Zeek 深度探索 Ch44：Zeek 与 SIEM 及威胁情报平台集成

## 概述

Zeek的安全价值不仅限于其本身的检测能力，更在于能够与安全信息和事件管理系统(SIEM)以及威胁情报平台集成，形成完整的安全运营体系。本章介绍各种集成方案和实现方法。

## 日志输出格式

### JSON格式输出

```zeek
# 启用JSON格式日志
@load policy/tuning/json-logs.zeek

# 或者在命令行指定
zeek -e 'Log::default_output_format=Log::JSON' ...
```

### 自定义日志格式

```zeek
module CustomLog;

export {
    global write_custom_log: event(rec: CustomRecord);
}

event CustomLog::write_custom_log(rec: CustomRecord) {
    local line = fmt("%s|%s|%s|%s",
        strftime("%Y-%m-%d %H:%M:%S", rec$ts),
        rec$src,
        rec$dst,
        rec$alert_type
    );
    Log::write(CustomLog::LOG, line);
}
```

## SIEM集成

### Elasticsearch集成

#### 使用Elasticsearch输出插件

```bash
# 安装elasticsearch插件
zkg install elasticsearch
```

```zeek
# elasticsearch.zeek
@load plugins/elasticsearch

event zeek_init() {
    Elasticsearch::connect([
        $host="127.0.0.1",
        $port=9200,
        $stream_prefix="zeek"
    ]);
    
    # 为不同日志创建索引
    Log::create_stream(Conn::LOG, [
        $writer=Elasticsearch::Writer,
        $idx=Elasticsearch::Index("zeek-conn")
    ]);
}
```

#### 使用Filebeat收集日志

```yaml
# /etc/filebeat/filebeat.yml
filebeat.inputs:
- type: log
  enabled: true
  paths:
    - /var/log/zeek/*.log
  json.keys_under_root: true
  json.add_error_key: true

output.elasticsearch:
  hosts: ["elasticsearch:9200"]
  index: "zeek-%{+yyyy.MM.dd}"

setup.template.name: "zeek"
setup.template.pattern: "zeek-*"
```

#### Elasticsearch索引模板

```json
{
  "index_patterns": ["zeek-*"],
  "template": {
    "settings": {
      "number_of_shards": 2,
      "number_of_replicas": 1
    },
    "mappings": {
      "properties": {
        "ts": { "type": "date" },
        "uid": { "type": "keyword" },
        "id.orig_h": { "type": "ip" },
        "id.resp_h": { "type": "ip" },
        "proto": { "type": "keyword" }
      }
    }
  }
}
```

### Splunk集成

#### HTTP Event Collector方式

```zeek
# splunk-hec.zeek
module SplunkHEC;

export {
    global splunk_hec_url: string = "https://splunk-server:8088/services/collector";
    global splunk_token: string = "your-hec-token";
}

function send_to_splunk(data: string) {
    local headers: table[string] of string = {
        ["Authorization"] = fmt("Splunk %s", splunk_token),
        ["Content-Type"] = "application/json"
    };
    
    # 使用curl发送数据
    local cmd = fmt(
        "curl -k -X POST '%s' -H 'Authorization: Splunk %s' -d '%s'",
        splunk_hec_url, splunk_token, data
    );
    system(cmd);
}

event Conn::log(rec: Conn::Info) {
    local json = to_json(rec);
    send_to_splunk(json);
}
```

#### 使用Splunk TaCloudzeek

```bash
# 安装Splunk支持的Zeek输出插件
# 在Splunk中添加TaCloudzeek应用
```

### Splunk连接器配置

```yaml
# inputs.conf for Splunk UF
[monitor:///var/log/zeek]
disabled = false
followTail = 0
host = zeek-sensor-1
index = zeek
sourcetype = zeek:json
```

### QRadar集成

#### Syslog方式

```zeek
# qradar.zeek
@load policy/files/zeek_syslog

# 配置远程syslog
redef Syslog::destinations += {
    [$host=1.2.3.4, $port=514, $proto=TCP]
};
```

```bash
# /etc/rsyslog.conf
# 配置QRadar接收
template(name="QRadarFormat" type="string" string="%msg%\n")

action(type="omfwd" target="qradar-server" port="514" 
       protocol="tcp" template="QRadarFormat")
```

#### QRadar DSM配置

```
# QRadar中配置Zeek日志源
# Log Source Type: Zeek Network Monitor
# Protocol: Syslog
# Events: JSON format
```

### ArcSight集成

```zeek
# arcsight.zeek
module ArcSight;

export {
    global arcsight_cefs: event(rec: any);
}

event ArcSight::arcsight_cefs(rec: any) {
    # CEF格式输出
    local cef = fmt(
        "CEF:0|Zeek|Security|1.0|%s|%s|5|src=%s dst=%s spt=%s dpt=%s",
        rec$alert_type,
        rec$alert_msg,
        rec$src_ip,
        rec$dst_ip,
        rec$src_port,
        rec$dst_port
    );
    
    # 发送到ArcSight
    system(fmt("echo '%s' | nc arcsight-server 514", cef));
}
```

## 威胁情报集成

### 威胁情报源

#### MISP (Malware Information Sharing Platform)

```zeek
# misp.zeek
module MISP;

export {
    global misp_server: string = "https://misp-server";
    global misp_key: string = "your-misp-api-key";
    global threat_indicators: table[string] of ThreatIndicator;
}

type ThreatIndicator: record {
    indicator_type: string;
    value: string;
    context: string;
    confidence: count;
};

function query_misp_attribute(indicator: string): ThreatIndicator {
    # 实际实现需要使用curl调用MISP API
    return ThreatIndicator($indicator_type="ip", $value=indicator, 
                          $context="test", $confidence=50);
}

event connection_established(c: connection) {
    local orig = fmt("%s", c$id$orig_h);
    
    if (orig in threat_indicators) {
        Log::write(MISP::LOG, [
            $ts=current_time(),
            $src=c$id$orig_h,
            $indicator=threat_indicators[orig]$value,
            $context=threat_indicators[orig]$context
        ]);
    }
}
```

#### AlienVault OTX

```zeek
# otx.zeek
module AlienVaultOTX;

export {
    global otx_api_key: string = "your-otx-key";
    global pulse_cache: table[string] of PulseInfo;
}

type PulseInfo: record {
    name: string;
    indicators: vector of string;
    created: time;
};

function check_otx_pulse(indicator: string): PulseInfo {
    # 调用OTX API检查指标
    return PulseInfo($name="test", $indicators=vector(), $created=current_time());
}
```

#### VirusTotal

```zeek
# virustotal.zeek
module VirusTotal;

export {
    global vt_api_key: string = "your-vt-api-key";
    global vt_cache: table[string] of VTResponse;
}

type VTResponse: record {
    malicious: count;
    suspicious: count;
    harmless: count;
    last_analysis: string;
};

function check_virustotal(hash: string): VTResponse {
    # 调用VirusTotal API
    return VTResponse($malicious=0, $suspicious=0, 
                     $harmless=1, $last_analysis="clean");
}
```

### 本地威胁情报匹配

```zeek
# threat-intel.zeek
module ThreatIntel;

export {
    global ioc_log: Log::Stream;
    
    global mal_ips: set[addr];
    global mal_domains: set[string];
    global mal_hashes: set[string];
}

type IOCInfo: record {
    ts: time;
    ioc_type: string;
    ioc_value: string;
    source: string;
    confidence: count;
};

function load_threat_intel(path: string) {
    # 从文件加载威胁指标
    for (line in Reader::read_lines(path)) {
        local parts = split_string(line, /\t/);
        if (|parts| >= 2) {
            local ioc_type = parts[0];
            local ioc_value = parts[1];
            
            if (ioc_type == "ip") {
                add mal_ips[to_addr(ioc_value)];
            } else if (ioc_type == "domain") {
                add mal_domains[ioc_value];
            } else if (ioc_type == "hash") {
                add mal_hashes[ioc_value];
            }
        }
    }
}

event dns_request(c: connection, msg: dns_msg, query: string, qtype: count) {
    if (query in mal_domains) {
        Log::write(ioc_log, [
            $ts=current_time(),
            $ioc_type="domain",
            $ioc_value=query,
            $source="local-ti",
            $confidence=100
        ]);
    }
}

event connection_established(c: connection) {
    if (c$id$orig_h in mal_ips) {
        Log::write(ioc_log, [
            $ts=current_time(),
            $ioc_type="ip",
            $ioc_value=fmt("%s", c$id$orig_h),
            $source="local-ti",
            $confidence=100
        ]);
    }
}

event file_hash(f: fa_file, hash: string) {
    if (hash in mal_hashes) {
        Log::write(ioc_log, [
            $ts=current_time(),
            $ioc_type="hash",
            $ioc_value=hash,
            $source="local-ti",
            $confidence=100
        ]);
    }
}
```

### 动态威胁情报更新

```zeek
# ti-update.zeek
module ThreatIntelUpdate;

event zeek_init() {
    # 每小时更新威胁情报
    schedule 1 hr { update_threat_intel() };
}

event update_threat_intel() {
    local ti_files = vector(
        "/opt/zeek/etc/threat-intel/malicious-ips.txt",
        "/opt/zeek/etc/threat-intel/malicious-domains.txt"
    );
    
    for (f in ti_files) {
        ThreatIntel::load_threat_intel(f);
    }
    
    # 下一次更新
    schedule 1 hr { update_threat_intel() };
}
```

## 自动响应集成

### 自动封锁

```zeek
# auto-block.zeek
module AutoBlock;

export {
    global block_threshold: count = 5;
    global recent_blocks: table[addr] of count;
}

function block_ip(ip: addr) {
    # 调用防火墙封锁IP
    local cmd = fmt("iptables -A INPUT -s %s -j DROP", ip);
    system(cmd);
    
    print fmt("Blocked: %s", ip);
}

event connection_established(c: connection) {
    local src = c$id$orig_h;
    
    if (src in recent_blocks) {
        recent_blocks[src] += 1;
    } else {
        recent_blocks[src] = 1;
    }
    
    if (recent_blocks[src] >= block_threshold) {
        block_ip(src);
    }
}
```

### 自动化工作流

```zeek
# webhook-response.zeek
module WebhookResponse;

export {
    global webhook_url: string = "https://soar-platform/webhook";
}

function send_webhook(alert: Notice::Info) {
    local payload = fmt(
        `{"alert": "%s", "src": "%s", "dst": "%s", "timestamp": "%s"}`,
        alert$msg, alert$src, alert$dst, alert$ts
    );
    
    local cmd = fmt(
        "curl -X POST -H 'Content-Type: application/json' -d '%s' %s",
        payload, webhook_url
    );
    system(cmd);
}

event Notice::policy(c: connection, msg: string, dst: addr) {
    send_webhook($msg=msg, $src=c$id$orig_h, $dst=dst, $ts=current_time());
}
```

## 集成最佳实践

### 日志规范化

```zeek
# 所有日志使用统一格式
type ZeekEvent: record {
    ts: time;
    sensor_id: string;
    event_type: string;
    source_ip: addr;
    source_port: port;
    dest_ip: addr;
    dest_port: port;
    protocol: string;
    metadata: table[string] of string;
};
```

### 性能考虑

```zeek
# 使用异步发送避免阻塞
module AsyncSIEM;

global log_queue: queue of string;

event async_siem_sender() {
    while (|log_queue| > 0) {
        local data = pop(log_queue);
        send_to_siem(data);
    }
    schedule 1 sec { async_siem_sender() };
}

event zeek_init() {
    schedule 1 sec { async_siem_sender() };
}
```

### 安全考虑

```bash
# 保护API密钥
chmod 600 /opt/zeek/etc/secrets/*
chown zeek:zeek /opt/zeek/etc/secrets/*

# 使用环境变量
export MISP_API_KEY="your-key"
export SPLUNK_TOKEN="your-token"
```

## 监控和维护

### 集成健康检查

```zeek
# health-check.zeek
module IntegrationHealth;

export {
    global health_log: Log::Stream;
    global last_siem_success: time;
    global siem_failures: count;
}

event siem_health_check() {
    if (current_time() - last_siem_success > 5 mins) {
        siem_failures += 1;
        
        if (siem_failures > 3) {
            # 发送告警
            Reporter::error(fmt("SIEM integration failing: %d consecutive failures", 
                               siem_failures));
        }
    }
    
    schedule 1 min { siem_health_check() };
}

event zeek_init() {
    schedule 1 min { siem_health_check() };
}
```

## 总结

Zeek与SIEM及威胁情报平台的集成为安全运营提供了强大的数据基础和自动化响应能力。通过合理配置日志输出、选择合适的集成方式并遵循最佳实践，可以构建高效的安全运营体系，有效提升威胁检测和响应能力。
