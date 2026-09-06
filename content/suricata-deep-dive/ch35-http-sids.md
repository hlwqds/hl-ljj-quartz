---
title: "Suricata 深度探索 (三十五)：HTTP 规则"
date: 2026-04-15
tags:
  - suricata
  - series
  - detection
  - http
  - rules
  - http.uri
  - http.header
description: "深入解析 Suricata HTTP 检测规则：http.* 关键字体系、HTTP 规范修饰符、uri/header/cookie/body 检测、HTP 库集成与配置源码映射"
---

> [!info] Suricata 2026 深度探索系列 0. [[suricata-deep-dive|全栈学习路径总览]]
> ... 33. [[ch33-unified2|第三十三章：Unified2]] 34. [[ch34-rules|第三十四章：规则语法]]
> **35. 当前章节：HTTP 规则**

---

## 1. HTTP 关键字体系概述

Suricata 通过 HTP 库解析 HTTP 流量，提供丰富的 `http.*` 关键字集合：

```snort
# HTTP 规则示例
alert tcp $HOME_NET any -> $EXTERNAL_NET $HTTP_PORTS (
    msg:"ET TROJAN Trickbot HTTP GET";
    flow:to_server,established;
    content:"/path/to/malware.exe";
    http.uri;           # 在 URI 部分匹配
    pcre:"/\/download[0-9]*\.exe$/U";
    content:"User-Agent|3a| Mozilla/4.0";
    http.header;        # 在 HTTP 头中匹配
    sid:2020493;
    rev:2;
)
```

### 1.1 HTTP 关键字列表

| 关键字               | 匹配位置       | 说明                               |
| :------------------- | :------------- | :--------------------------------- |
| `http.uri`           | URI 路径       | 完整 URI 路径（不含 query string） |
| `http.uri.raw`       | 原始 URI       | URL 编码前的 URI                   |
| `http.request_line`  | 完整请求行     | 方法 + URI + 版本                  |
| `http.request_body`  | 请求 Body      | POST 数据                          |
| `http.header`        | 通用头         | 所有请求/响应头                    |
| `http.header.raw`    | 原始头         | 未经规范化的头                     |
| `http.cookie`        | Cookie 头      | Cookie 值                          |
| `http.user_agent`    | User-Agent     | 用户代理字符串                     |
| `http.host`          | Host 头        | 目标主机                           |
| `http.host.raw`      | 原始 Host      | 未经规范化的 Host                  |
| `http.response_line` | 响应状态行     | 状态码 + 消息                      |
| `http.stat_code`     | 状态码         | 响应状态码                         |
| `http.stat_msg`      | 状态消息       | 响应状态描述                       |
| `http.response_body` | 响应 Body      | 服务器响应内容                     |
| `http.content_type`  | Content-Type   | 内容类型                           |
| `http.content_len`   | Content-Length | 内容长度                           |
| `http.location`      | Location 头    | 重定向目标                         |

---

## 2. HTTP URI 检测

### 2.1 http.uri 详解

`http.uri` 修饰符将 `content` 匹配的搜索范围限定在 HTTP URI 路径部分（不含 query string）：

```snort
# 示例：检测 /admin/login.php
alert http any any -> any any (
    content:"/admin/login.php";
    http.uri;
)
```

```
# HTTP 请求分解
GET /admin/login.php?user=admin&pass=123 HTTP/1.1\r\n
Host: example.com\r\n
...
     ^^^^^^^^^^^^^^^^ http.uri 匹配区域
                         ^^^^^^^^^^^^^^^^^^^^ http.query 匹配区域
```

### 2.2 http.uri 源码解析

```c
// src/detect-http-uri.c — http.uri 关键字注册
void RegisterHttpUri(void)
{
    sigmatch_table[DETECT_HTTP_URI].name = "http.uri";
    sigmatch_table[DETECT_HTTP_URI].desc = "HTTP URI content match";
    sigmatch_table[DETECT_HTTP_URI].Match = DetectHttpUriMatch;
    sigmatch_table[DETECT_HTTP_URI].Setup = DetectHttpUriSetup;
    sigmatch_table[DETECT_HTTP_URI].Free = DetectHttpUriFree;
}

static int DetectHttpUriSetup(char *optstr, Signature *sig)
{
    DetectHttpUriData *data = SCCalloc(1, sizeof(DetectHttpUriData));

    /* 解析 http.uri; 选项 */
    /* 设置匹配标志 */
    data->flags |= HTTP_URI;

    /* 查找之前的 content 关键字 */
    DetectContentData *cd = GetLastContent(sig);
    if (cd == NULL) {
        SCLogError("http.uri requires preceding content match");
        return -1;
    }

    /* 将 content 标记为 HTTP URI 匹配 */
    cd->flags |= CONTENT_HTTP_URI;

    /* 添加到签名 */
    data->next = sig->http_uri;
    sig->http_uri = data;

    return 0;
}

static int DetectHttpUriMatch(void *tx, void *data)
{
    DetectHttpUriData *hd = (DetectHttpUriData *)data;
    HtpTx *tx = (HtpTx *)tx;

    /* 获取解码后的 URI */
    bstr *uri = htp_tx_request_uri(tx);
    if (uri == NULL) {
        return 0;
    }

    /* 遍历 URI 中的 content 列表 */
    for (DetectContentData *cd = tx->uri_cont; cd != NULL; cd = cd->next) {
        if (cd->flags & CONTENT_HTTP_URI) {
            if (BstrCmpi(uri, cd->content, cd->content_len) == 0) {
                return 1;  // 匹配
            }
        }
    }

    return 0;
}
```

### 2.3 http.uri.raw 详解

```snort
# 检测 URL 编码绕过
alert http any any -> any any (
    content:"/admin%252elogin";  # %25 = '%', 最终变为 %.login
    http.uri.raw;  # 匹配原始（未解码）URI
)
```

```c
// src/detect-http-uri.c — raw URI 解析
static int DetectHttpUriRawMatch(void *tx, void *data)
{
    HtpTx *htx = (HtpTx *)tx;

    /* 获取原始（未解码）URI */
    bstr *raw_uri = htp_tx_request_uri_raw(htx);
    if (raw_uri == NULL) {
        return 0;
    }

    /* 在原始 URI 上进行匹配 */
    return DetectContentMatch(raw_uri, data);
}
```

---

## 3. HTTP Header 检测

### 3.1 http.header 详解

```snort
# 检测恶意 User-Agent
alert http any any -> any any (
    content:"User-Agent|3a|";
    http.header;  # 在 HTTP 头中匹配
    content:"malware-bot";
    http.header;
    nocase;
)
```

### 3.2 http.header 源码解析

```c
// src/detect-http-header.c — http.header 关键字
typedef struct DetectHttpHeaderData_ {
    uint8_t *header;               // 头名称
    uint16_t header_len;           // 头名称长度
    uint8_t *value;                // 头值
    uint16_t value_len;           // 头值长度
    uint8_t flags;
#define HTTP_HEADER_REQUEST    0x01  // 请求头
#define HTTP_HEADER_RESPONSE   0x02  // 响应头
#define HTTP_HEADER_RAW        0x04  // 原始头
} DetectHttpHeaderData;

static int DetectHttpHeaderSetup(char *optstr, Signature *sig)
{
    DetectHttpHeaderData *data = SCCalloc(1, sizeof(DetectHttpHeaderData));

    /* 解析 http.header; 或带值的格式 */
    /* 查找 content 关键字并标记 */
    DetectContentData *cd = GetLastContent(sig);
    if (cd == NULL) {
        SCLogError("http.header requires preceding content match");
        return -1;
    }

    /* 标记为 HTTP 头匹配 */
    cd->flags |= CONTENT_HTTP_HEADER;

    return 0;
}

static int DetectHttpHeaderMatch(void *tx, void *data)
{
    HtpTx *htx = (HtpTx *)tx;

    /* 遍历所有请求头 */
    for (int i = 0; i < htp_table_size(htx->request_headers); i++) {
        htp_header_t *h = htp_table_get_index(htx->request_headers, i);

        /* 在头值中匹配 */
        bstr *value = htp_header_value(h);
        if (DetectContentMatch(value, data)) {
            return 1;
        }
    }

    return 0;
}
```

### 3.3 常见 HTTP 头检测规则

```snort
# 检测恶意 Referer
alert http any any -> any any (
    content:"Referer|3a|";
    http.header;
    content:"malware-site.com";
    http.header;
)

# 检测异常 Content-Type
alert http any any -> $EXTERNAL_NET any (
    content:"Content-Type|3a|";
    http.header;
    content:"application/x-shockwave-flash";
    pcre:"/application\/x-shockwave-flash/R";
)

# 检测过长 Host
alert http any any -> any any (
    content:"Host|3a|";
    http.header;
    content:"|0a|";  # 检测换行注入
    http.header.raw;
)
```

---

## 4. HTTP Body 检测

### 4.1 http.request_body 详解

```snort
# 检测 POST 登录表单中的凭据泄露
alert http any any -> any any (
    msg:"Potential credential theft via POST";
    flow:to_server,established;
    content:"username=";
    http.request_body;
    content:"&password=";
    http.request_body;
)
```

### 4.2 http.response_body 详解

```snort
# 检测响应中的敏感信息
alert http any any -> any any (
    msg:"Sensitive data in response";
    flow:to_server,established;
    content:"Credit Card|3a|";
    http.response_body;
    pcre:"/[0-9]{13,16}/";
    http.response_body;
)
```

### 4.3 body 匹配源码

```c
// src/detect-http-body.c — body 检测结构
typedef struct DetectHttpBodyData_ {
    DetectContentData *content;    // 内容匹配数据
    uint8_t flags;
#define HTTP_BODY_REQUEST     0x01  // 请求 body
#define HTTP_BODY_RESPONSE    0x02  // 响应 body
#define HTTP_BODY_MULTIPART   0x04  // Multipart 编码
} DetectHttpBodyData;

static int DetectHttpRequestBodyMatch(void *tx, void *data)
{
    HtpTx *htx = (HtpTx *)tx;
    DetectHttpBodyData *bodyd = (DetectHttpBodyData *)data;

    /* 获取已重组的请求 body */
    HtpBody *body = &htx->request_body;

    /* 遍历 body 数据块 */
    for (int i = 0; i < body->chunks; i++) {
        HtpBodyChunk *chunk = &body->chunk[i];

        /* 在 body 数据中搜索 */
        if (DetectContentMatch(chunk->data, chunk->len, bodyd->content)) {
            return 1;
        }
    }

    return 0;
}
```

---

## 5. HTTP Cookie 检测

### 5.1 http.cookie 详解

```snort
# 检测特定 Cookie 值
alert http any any -> any any (
    content:"Cookie|3a|";
    http.cookie;
    content:"sessionid=";
    http.cookie;
    content:"admin";
    http.cookie;
)
```

```
# HTTP 请求分解
GET /admin HTTP/1.1\r\n
Host: example.com\r\n
Cookie: sessionid=abc123; admin=1\r\n
     ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ http.cookie 匹配区域
```

### 5.2 http.set-cookie 详解

```snort
# 检测 Set-Cookie 响应头
alert http any any -> any any (
    content:"Set-Cookie|3a|";
    http.header;
    content:"HttpOnly";
    http.header;
    content:"Secure";
    http.header;
)
```

---

## 6. HTTP 规范化配置

### 6.1 libhtp 配置

```yaml
# suricata.yaml
libhtp:
  default-config:
    # URI 规范化
    uri-include-all: false
    decode-url-encations: true

    # 头规范化
    http-body-inline: true
    request-body-limit: 4096
    response-body-limit: 4096

    # 编码处理
    double-decode-path: false
    double-decode-query: false

  server-config:
    - host: $HOME_NET
      default-config:
        personality: IDS
        request-body-limit: 4096
```

### 6.2 规范化级别

|   级别    | 说明           | 配置                        |
| :-------: | :------------- | :-------------------------- |
| `Minimal` | 仅解码标准编码 | `decode-utf-8: yes`         |
|   `Low`   | 基础规范化     | `decode-url-encations: yes` |
| `Medium`  | 中等级别       | `remove-enc-headers: yes`   |
|  `High`   | 激进规范化     | `double-decode-*`           |

```c
// src/app-layer-htp.c — 规范化配置
typedef enum {
    HTTP inspect_mode_MINIMIZE = 0,
    HTTP_inspect_mode_LOW,
    HTTP_inspect_mode_MEDIUM,
    HTTP_inspect_mode_HIGH,
} HTTPInspectMode;

static int HTTPProcessRequestUri(HtpTx *tx, HTTPInspectCtx *ctx)
{
    bstr *uri = htp_tx_request_uri(tx);

    if (ctx->decode_url_encodings) {
        /* URL 解码 */
        uri = HtpDecodeUrlEncoding(uri);
    }

    if (ctx->uri_include_all) {
        /* 保留完整 URI */
        tx->uri_raw = bstr_dup(uri);
    } else {
        /* 仅保留路径部分 */
        tx->uri = ExtractUriPath(uri);
    }

    return 0;
}
```

---

## 7. HTTP 规则常见模式

### 7.1 恶意软件下载检测

```snort
# 检测可执行文件下载
alert http any any -> $EXTERNAL_NET any (
    msg:"MALWARE-downloaded-executable";
    flow:to_server,established;
    content:"GET";
    http.request_line;
    content:".exe";
    http.uri;
    content:"Content-Type|3a| application/octet-stream";
    http.header;
    classtype:trojan-activity;
    sid:2002001;
    rev:1;
)

# 检测伪装的 MIME 类型
alert http any any -> $EXTERNAL_NET any (
    msg:"MALWARE-suspicious-mime-type";
    flow:to_server,established;
    content:"Content-Type|3a|";
    http.header;
    content:"application/x-msdownload";
    http.header;
    nocase;
    sid:2002002;
    rev:1;
)
```

### 7.2 SQL 注入检测

```snort
# 检测 SQL 注入特征
alert http any any -> any any (
    msg:"ATTACK SQL injection attempt";
    flow:to_server,established;
    content:"SELECT";
    http.request_body;
    content:"FROM";
    http.request_body;
    pcre:"/(union|select|insert|update|delete)\s+/i";
    http.request_body;
    sid:2003001;
    rev:1;
)
```

### 7.3 XSS 检测

```snort
# 检测 XSS 特征
alert http any any -> any any (
    msg:"ATTACK XSS script injection";
    flow:to_server,established;
    content:"<script>";
    http.request_body;
    content:"javascript:";
    http.request_body;
    sid:2004001;
    rev:1;
)

# 检测编码的 XSS
alert http any any -> any any (
    msg:"ATTACK encoded XSS";
    flow:to_server,established;
    content:"%3Cscript%3E";
    http.uri.raw;
    sid:2004002;
    rev:1;
)
```

---

## 8. HTTP 检测引擎集成

### 8.1 HTP 回调注册

```c
// src/app-layer-htp.c — HTP 解析器注册
int HTPRegister(void)
{
    /* 注册协议 */
    AppLayerRegisterProtocol(&hTP);

    /* 注册 HTP 库回调 */
    htp_config_register_request(httcp->cfg, HTPRequestCallback);
    htp_config_register_response(httcp->cfg, HTPResponseCallback);
    htp_config_register_request_line_data(httcp->cfg, HTPRequestLineCallback);
    htp_config_register_response_line_data(httcp->cfg, HTPResponseLineCallback);
    htp_config_register_header_data(httcp->cfg, HTPHeaderCallback);

    return 0;
}

static int HTPRequestCallback(htp_tx_t *tx)
{
    HtpTx *hhtx = SCCalloc(1, sizeof(HtpTx));

    /* 存储解析后的数据 */
    hhtx->tx = tx;
    hhtx->request_uri = htp_tx_request_uri(tx);
    hhtx->request_method = htp_tx_request_method(tx);
    hhtx->request_protocol = htp_tx_request_protocol(tx);

    /* 触发 HTTP 检测 */
    DetectEngineRun(HTTP_STATE, hhtx);

    return 0;
}
```

---

## 9. 总结

HTTP 检测是 Suricata 应用层检测的核心，通过 `http.*` 关键字体系实现了对 HTTP 协议各部分的精细化检测。`http.uri` 和 `http.uri.raw` 分别处理规范化和原始 URI，`http.header` 和 `http.header.raw` 处理 HTTP 头，`http.cookie` 专门处理 Cookie 数据，`http.request_body` 和 `http.response_body` 处理消息体。这些关键字通过 HTP 库与 Suricata 检测引擎集成，在 libhtp 配置的支持下实现灵活的规范化策略。
