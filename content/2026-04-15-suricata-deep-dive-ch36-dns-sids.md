---
title: "Suricata 深度探索 (三十六)：DNS 规则"
date: 2026-04-15
tags:
  - suricata
  - series
  - detection
  - dns
  - rules
  - dns.query
  - dns.answer
description: "深入解析 Suricata DNS 检测规则：dns.* 关键字体系、查询/响应检测、DNS-over-HTTPS 解析、日志字段与检测引擎源码映射"
---

> [!info] Suricata 2026 深度探索系列
> 0. [[2026-04-15-suricata-deep-dive-series-index|全栈学习路径总览]]
> ...
> 34. [[2026-04-15-suricata-deep-dive-ch34-rules|第三十四章：规则语法]]
> 35. [[2026-04-15-suricata-deep-dive-ch35-http-sids|第三十五章：HTTP 规则]]
> **36. 当前章节：DNS 规则**

---

## 1. DNS 关键字体系概述

Suricata 提供专门针对 DNS 协议的检测关键字，支持查询和响应的精细化检测：

```snort
# DNS 规则示例
alert dns any any -> any any (
    msg:"DNS query to known malware domain";
    dns.query;
    content:"evilsite.com";
    dns.queried;
    sid:2000010;
    rev:1;
)
```

### 1.1 DNS 关键字列表

| 关键字 | 匹配位置 | 说明 |
|:---|:---|:---|
| `dns.query` | 查询名称 | DNS 查询中的域名 |
| `dns.query.raw` | 原始查询 | 未规范化的域名 |
| `dns.queried` | 查询的域名 | 与查询记录关联 |
| `dns.answer` | 响应答案 | DNS 响应中的记录 |
| `dns.answer.raw` | 原始响应 | 未规范化的响应 |
| `dns.rcode` | 响应码 | DNS 响应状态码 |
| `dns.qtype` | 查询类型 | 查询类型（A/AAAA/MX 等） |
| `dns.rrname` | 资源记录名 | 资源记录名称 |
| `dns.rdata` | 资源数据 | 记录关联的数据 |

---

## 2. DNS 查询检测

### 2.1 dns.query 详解

`dns.query` 将 content 匹配的搜索范围限定在 DNS 查询的域名部分：

```snort
# 检测对恶意域名的 DNS 查询
alert dns any any -> any any (
    msg:"MALWARE DNS query to suspicious domain";
    dns.query;
    content:"badsite.ru";
)
```

```
# DNS 查询包分解
DNS Question Section:
    Name: badsite.ru        <- dns.query 匹配区域
    Type: A (1)
    Class: IN (1)
```

### 2.2 dns.query 源码解析

```c
// src/detect-dns-query.c — dns.query 关键字注册
void RegisterDnsQuery(void)
{
    sigmatch_table[DETECT_DNS_QUERY].name = "dns.query";
    sigmatch_table[DETECT_DNS_QUERY].desc = "DNS query match";
    sigmatch_table[DETECT_DNS_QUERY].Match = DetectDnsQueryMatch;
    sigmatch_table[DETECT_DNS_QUERY].Setup = DetectDnsQuerySetup;
    sigmatch_table[DETECT_DNS_QUERY].Free = DetectDnsQueryFree;
}

typedef struct DetectDnsQueryData_ {
    uint8_t *domain;              // 域名（已规范化）
    uint16_t domain_len;          // 域名长度
    uint8_t type;                 // 查询类型 (A/AAAA/MX 等)
    uint8_t flags;
#define DNS_QUERY_LOWER          0x01  // 转换为小写
#define DNS_QUERY_CASE Sensitive  0x02  // 区分大小写
} DetectDnsQueryData;

static int DetectDnsQuerySetup(char *optstr, Signature *sig)
{
    DetectDnsQueryData *data = SCCalloc(1, sizeof(DetectDnsQueryData));
    
    /* 解析 dns.query; 选项 */
    /* 可以带类型: dns.query;A */
    
    if (strchr(optstr, ';')) {
        /* 带类型的格式: dns.query; A */
        char *type_str = strchr(optstr, ';') + 1;
        data->type = DnsQueryTypeFromString(type_str);
    }
    
    /* 查找关联的 content 关键字 */
    DetectContentData *cd = GetLastContent(sig);
    if (cd == NULL) {
        SCLogError("dns.query requires preceding content match");
        return -1;
    }
    
    /* 标记 content 为 DNS 查询匹配 */
    cd->flags |= CONTENT_DNS_QUERY;
    
    return 0;
}

static int DetectDnsQueryMatch(DNSState *dns_state, DNSQuery *query, void *data)
{
    DetectDnsQueryData *dd = (DetectDnsQueryData *)data;
    
    /* 获取查询域名 */
    bstr *query_name = query->name;
    
    /* 域名规范化（转小写） */
    if (!(dd->flags & DNS_QUERY_CASE_SENSITIVE)) {
        query_name = bstr_lower(query_name);
    }
    
    /* 内容匹配 */
    if (BstrCmpi(query_name, dd->domain, dd->domain_len) == 0) {
        /* 检查类型过滤 */
        if (dd->type == 0 || query->type == dd->type) {
            return 1;  // 匹配
        }
    }
    
    return 0;
}
```

### 2.3 dns.queried 详解

```snort
# 检测对特定域名的查询（可关联多个规则）
alert dns any any -> any any (
    msg:"Suspicious DNS query";
    dns.queried;
    content:"suspicious-domain.com";
)

alert dns any any -> any any (
    msg:"Second stage domain query";
    dns.queried;
    content:"c2.malware.com";
    sid:2000020;
)
```

---

## 3. DNS 响应检测

### 3.1 dns.answer 详解

```snort
# 检测恶意 DNS 响应
alert dns any any -> any any (
    msg:"MALWARE DNS sinkhole response";
    dns.answer;
    content:"192.168.1.100";  # Sinkhole IP
)
```

### 3.2 dns.answer 源码解析

```c
// src/detect-dns-answer.c — dns.answer 关键字
typedef struct DetectDnsAnswerData_ {
    uint8_t *rdata;               // 响应数据（IP/域名等）
    uint16_t rdata_len;           // 响应数据长度
    uint8_t type;                // 记录类型
    uint8_t flags;
#define DNS_ANSWER_IPV4         0x01  // IPv4 地址
#define DNS_ANSWER_IPV6         0x02  // IPv6 地址
#define DNS_ANSWER_DOMAIN       0x04  // 域名
} DetectDnsAnswerData;

static int DetectDnsAnswerMatch(DNSState *dns_state, DNSAnswer *answer, void *data)
{
    DetectDnsAnswerData *dd = (DetectDnsAnswerData *)data;
    
    /* 遍历答案列表 */
    for (int i = 0; i < answer->count; i++) {
        DNSResourceRecord *rr = &answer->rr[i];
        
        /* 类型检查 */
        if (dd->type != 0 && rr->type != dd->type) {
            continue;
        }
        
        /* 数据匹配 */
        switch (rr->type) {
            case DNS_TYPE_A:
                if (dd->flags & DNS_ANSWER_IPV4) {
                    if (MatchIPv4Address(rr->rdata, dd->rdata)) {
                        return 1;
                    }
                }
                break;
            case DNS_TYPE_AAAA:
                if (dd->flags & DNS_ANSWER_IPV6) {
                    if (MatchIPv6Address(rr->rdata, dd->rdata)) {
                        return 1;
                    }
                }
                break;
            case DNS_TYPE_CNAME:
            case DNS_TYPE_MX:
                if (dd->flags & DNS_ANSWER_DOMAIN) {
                    if (BstrCmpi(rr->rdata, dd->rdata, dd->rdata_len) == 0) {
                        return 1;
                    }
                }
                break;
        }
    }
    
    return 0;
}
```

---

## 4. DNS 查询类型过滤

### 4.1 dns.qtype 详解

```snort
# 仅检测 A 记录查询
alert dns any any -> any any (
    msg:"DNS A record query";
    dns.qtype;
    content:"A";
)

# 检测 TXT 记录查询（常用于 DNS 隧道）
alert dns any any -> any any (
    msg:"DNS TXT query - potential tunneling";
    dns.qtype;
    content:"TXT";
    threshold:type threshold, track by_src, count 5, seconds 60;
)
```

### 4.2 常见 DNS 查询类型

| 类型 | 值 | 说明 |
|:---|:---:|:---|
| A | 1 | IPv4 地址 |
| AAAA | 28 | IPv6 地址 |
| MX | 15 | 邮件交换 |
| TXT | 16 | 文本记录 |
| CNAME | 5 | 别名 |
| NS | 2 | 名称服务器 |
| SOA | 6 | 授权起始 |
| PTR | 12 | 指针记录 |
| DNSKEY | 48 | DNS 密钥 |
| TXT | 16 | SPF 记录 |

```c
// src/detect-dns-query.c — 查询类型解析
static uint16_t DnsQueryTypeFromString(const char *type_str)
{
    if (strcmp(type_str, "A") == 0) return DNS_TYPE_A;
    if (strcmp(type_str, "AAAA") == 0) return DNS_TYPE_AAAA;
    if (strcmp(type_str, "MX") == 0) return DNS_TYPE_MX;
    if (strcmp(type_str, "TXT") == 0) return DNS_TYPE_TXT;
    if (strcmp(type_str, "CNAME") == 0) return DNS_TYPE_CNAME;
    if (strcmp(type_str, "NS") == 0) return DNS_TYPE_NS;
    if (strcmp(type_str, "SOA") == 0) return DNS_TYPE_SOA;
    if (strcmp(type_str, "PTR") == 0) return DNS_TYPE_PTR;
    if (strcmp(type_str, "DNSKEY") == 0) return DNS_TYPE_DNSKEY;
    if (strcmp(type_str, "RRSIG") == 0) return DNS_TYPE_RRSIG;
    if (strcmp(type_str, "NSEC") == 0) return DNS_TYPE_NSEC;
    if (strcmp(type_str, "ANY") == 0) return DNS_TYPE_ANY;
    
    return 0;
}
```

---

## 5. DNS 响应码检测

### 5.1 dns.rcode 详解

```snort
# 检测 NXDOMAIN 响应（域名不存在）
alert dns any any -> any any (
    msg:"DNS NXDOMAIN response";
    dns.rcode;
    content:"NXDOMAIN";
)

# 检测 SERVFAIL（服务器故障）
alert dns any any -> any any (
    msg:"DNS SERVFAIL response";
    dns.rcode;
    content:"SERVFAIL";
)
```

### 5.2 DNS 响应码

| RCODE | 名称 | 说明 |
|:---:|:---|:---|
| 0 | NOERROR | 无错误 |
| 1 | FORMERR | 格式错误 |
| 2 | SERVFAIL | 服务器故障 |
| 3 | NXDOMAIN | 域名不存在 |
| 4 | NOTIMP | 未实现 |
| 5 | REFUSED | 查询被拒绝 |

```c
// src/detect-dns-rcode.c — rcode 检测
typedef struct DetectDnsRcodeData_ {
    uint8_t rcode;                // 响应码
    const char *rcode_str;         // 响应码字符串
} DetectDnsRcodeData;

static int DetectDnsRcodeMatch(DNSState *dns_state, void *data)
{
    DetectDnsRcodeData *dd = (DetectDnsRcodeData *)data;
    
    /* 获取响应的 RCODE */
    uint8_t rcode = dns_state->rcode;
    
    return (rcode == dd->rcode) ? 1 : 0;
}
```

---

## 6. DNS-over-HTTPS 检测

### 6.1 DoH 检测配置

```yaml
# suricata.yaml
app-layer:
  protocols:
    http:
      enabled: true
      detection-ports:
        http: 80
        https: 443
    dns:
      enabled: true
      tcp:
        enabled: true
        detection-ports: 53
      udp:
        enabled: true
        detection-ports: 53
      # DNS-over-HTTPS 检测
      doh:
        enabled: true
        detection-ports:
          https: 443
```

### 6.2 DoH 检测规则

```snort
# 检测 DoH 查询
alert https any any -> any any (
    msg:"DNS-over-HTTPS query";
    flow:to_server,established;
    http.request_body;
    content:"|00 01|";  # DNS header: QR=0, OPCODE=0, RD=1
    content:"GET";
    http.request_line;
    content:"/dns-query";
    http.uri;
    dns.query;
    content:"malware-domain.com";
)
```

---

## 7. DNS 隧道检测规则

### 7.1 异常查询长度检测

```snort
# 检测超长子域名（DNS 隧道特征）
alert dns any any -> any any (
    msg:"DNS tunneling - long subdomain";
    dns.query;
    content:".";
    pcre:"/^[a-z]{50,}\.[a-z]+\./";
    threshold:type suppress, track by_src, count 1, seconds 60;
    sid:2000100;
    rev:1;
)
```

### 7.2 高频查询检测

```snort
# 检测 DNS 隧道的心跳特征
alert dns any any -> any any (
    msg:"DNS tunneling heartbeat detection";
    dns.query;
    content:"subdomain";
    threshold:type threshold, track by_src, count 100, seconds 60;
    sid:2000101;
    rev:1;
)
```

### 7.3 异常记录类型检测

```snort
# 检测 Tunnel 工具常用记录类型
alert dns any any -> any any (
    msg:"DNS tunneling - NULL/TXT type";
    dns.qtype;
    content:"NULL";
    sid:2000102;
)

alert dns any any -> any any (
    msg:"DNS tunneling - private type";
    dns.qtype;
    content:"TYPE65535";
    sid:2000103;
)
```

---

## 8. DNS 检测引擎集成

### 8.1 DNS 解析器注册

```c
// src/app-layer-dns.c — DNS 协议注册
int DNSRegister(void)
{
    AppLayerProtocol proto = {
        .name = "dns",
        .default_port = "53",
        .ipproto = IPPROTO_UDP,
        .Register = DNSRegisterProbe,
        .Init = DNSInit,
        .Deinit = DNSDeinit,
    };
    
    AppLayerRegister(&proto);
    
    /* 注册 UDP 检测 */
    DNSUDPRegister();
    
    /* 注册 TCP 检测 */
    DNSTCPRegister();
    
    return 0;
}

static int DNSUDPRegister(void)
{
    /* 端口配置 */
    AppLayerRegisterUDPPort(&dns_hdl, 53, DNSStateAlloc, DNSParseRequest);
    
    /* 注册解析状态 */
    AppLayerRegisterStateFuncs(DNS_STATEUDP, DNSStateFree);
    
    return 0;
}
```

### 8.2 DNS 状态机

```c
// src/app-layer-dns.c — DNS 状态
typedef struct DNSState_ {
    /* 事务状态 */
    uint16_t transaction_id;
    
    /* 查询信息 */
    DNSQuery **queries;
    uint16_t query_count;
    
    /* 响应信息 */
    DNSAnswer **answers;
    uint16_t answer_count;
    
    /* RCODE */
    uint8_t rcode;
    
    /* 协议版本 */
    uint8_t version;  // 1=TCP, 2=DNS-over-TLS, 3=DNS-over-HTTPS
} DNSState;

typedef enum {
    DNS_STATE_NONE = 0,
    DNS_STATE_QUERY_SENT,      // 查询已发送
    DNS_STATE_RESPONSE_RCVD,   // 响应已接收
    DNS_STATE_COMPLETE,        // 完成
} DNSStateEnum;
```

---

## 9. DNS 日志字段

### 9.1 EVE DNS 日志

```json
{
  "timestamp": "2026-04-15T10:30:00.123456Z",
  "event_type": "dns",
  "dns": {
    "type": "query",
    "id": 12345,
    "version": 2,
    "query": [
      {
        "name": "malware-site.com",
        "type": "A",
        "resolvedomain": false
      }
    ]
  }
}
```

### 9.2 DNS 日志配置

```yaml
# suricata.yaml
outputs:
  - eve-log:
      enabled: yes
      types:
        - dns:
            # 记录查询
            query: yes
            # 记录响应
            answer: yes
            # 记录 RCODE
            rcode: yes
            # 记录扩展 RCODE
            edns:
              present: yes
              client-subnet: yes
            # 记录事务时间
            transaction-id: yes
```

---

## 10. 总结

Suricata 的 DNS 检测系统通过 `dns.*` 关键字体系提供了精细化的 DNS 协议检测能力。`dns.query` 和 `dns.answer` 分别覆盖查询和响应，`dns.qtype` 支持按记录类型过滤，`dns.rcode` 支持响应状态检测。DNS-over-HTTPS 的检测需要结合 HTTP 检测上下文。DNS 隧道检测规则通常依赖异常长度、查询频率和特殊记录类型的组合来识别恶意流量。
