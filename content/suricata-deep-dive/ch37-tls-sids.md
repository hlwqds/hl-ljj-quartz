---
title: "Suricata 深度探索 (三十七)：TLS 规则"
date: 2026-04-15
tags:
  - suricata
  - series
  - detection
  - tls
  - ssl
  - rules
  - tls.subject
  - tls.issuerdn
description: "深入解析 Suricata TLS 检测规则：tls.* 关键字体系、证书检测、SNI 匹配、TLS 版本指纹、日志字段与检测引擎源码映射"
---

> [!info] Suricata 2026 深度探索系列 0. [[suricata-deep-dive|全栈学习路径总览]]
> ... 34. [[ch34-rules|第三十四章：规则语法]] 35. [[ch35-http-sids|第三十五章：HTTP 规则]] 36. [[ch36-dns-sids|第三十六章：DNS 规则]]
> **37. 当前章节：TLS 规则**

---

## 1. TLS 关键字体系概述

Suricata 通过 TLS 解析器提供丰富的 `tls.*` 关键字集合，用于检测 TLS/SSL 流量：

```snort
# TLS 规则示例
alert tls any any -> any any (
    msg:"MALWARE Suspicious TLS connection to known C2";
    flow:to_server,established;
    tls.subject;
    content:"C2.malware.com";
    tls.issuerdn;
    content:"Evil CA";
    sid:2001001;
    rev:1;
)
```

### 1.1 TLS 关键字列表

| 关键字                | 匹配位置   | 说明           |
| :-------------------- | :--------- | :------------- |
| `tls.subject`         | 证书主题   | 证书持有者信息 |
| `tls.issuerdn`        | 颁发者     | CA 证书信息    |
| `tls.fingerprint`     | 证书指纹   | SHA1/SPKI 指纹 |
| `tls.sni`             | SNI 扩展   | 服务器名称指示 |
| `tls.sni.raw`         | 原始 SNI   | 未规范化的 SNI |
| `tls.version`         | TLS 版本   | TLS/SSL 版本   |
| `tls.store`           | 存储的证书 | 已存储证书     |
| `tls.cert`            | 证书数据   | 完整证书信息   |
| `tls.cert.issuer`     | 颁发者信息 | 证书颁发者     |
| `tls.cert.subject`    | 主题信息   | 证书主题       |
| `tls.session.resumed` | 会话恢复   | 是否恢复会话   |
| `tls.ja3`             | JA3 指纹   | TLS 客户端指纹 |
| `tls.ja3s`            | JA3S 指纹  | TLS 服务端指纹 |

---

## 2. TLS 证书检测

### 2.1 tls.subject 详解

`tls.subject` 匹配 TLS 证书中的主题字段（持有者信息）：

```snort
# 检测连接到伪造的证书持有者
alert tls any any -> any any (
    msg:"MALWARE Fake certificate subject";
    tls.subject;
    content:"CN=apple.com, O=Apple Inc.";
)
```

### 2.2 tls.subject 源码解析

```c
// src/detect-tls-certificate.c — TLS 证书检测
typedef struct DetectTlsCertData_ {
    uint8_t *cert_field;          // 证书字段
    uint16_t cert_field_len;      // 字段长度
    uint8_t flags;
#define TLS_CERT_SUBJECT         0x01  // 主题
#define TLS_CERT_ISSUER          0x02  // 颁发者
#define TLS_CERT_SERIAL          0x04  // 序列号
#define TLS_CERT_FINGERPRINT      0x08  // 指纹
} DetectTlsCertData;

static int DetectTlsSubjectSetup(char *optstr, Signature *sig)
{
    DetectTlsCertData *data = SCCalloc(1, sizeof(DetectTlsCertData));

    /* 查找关联的 content */
    DetectContentData *cd = GetLastContent(sig);
    if (cd == NULL) {
        SCLogError("tls.subject requires preceding content match");
        return -1;
    }

    /* 标记为证书主题匹配 */
    cd->flags |= CONTENT_TLS_SUBJECT;
    data->flags |= TLS_CERT_SUBJECT;

    return 0;
}

static int DetectTlsSubjectMatch(void *tx, void *data)
{
    SSLState *ssl_state = (SSLState *)tx;
    DetectTlsCertData *cert_data = (DetectTlsCertData *)data;

    /* 获取证书 */
    SSLCertsChain *cert = ssl_state->server_certs;
    if (cert == NULL) {
        return 0;
    }

    /* 获取证书主题 */
    char *subject = X509GetSubject(cert->peer_cert);
    if (subject == NULL) {
        return 0;
    }

    /* 匹配内容 */
    int result = DetectContentMatch(subject, strlen(subject), cert_data);

    SCFree(subject);
    return result;
}

// src/app-layer-ssl.c — 证书解析
char *X509GetSubject(X509 *cert)
{
    char *subject = SCStackCalloc(256, sizeof(char));

    /* 获取主题字段 */
    X509_NAME *name = X509_get_subject_name(cert);
    if (name == NULL) {
        return NULL;
    }

    /* 格式化为字符串 */
    X509_NAME_oneline(name, subject, 256);

    return subject;
}
```

### 2.3 tls.issuerdn 详解

```snort
# 检测自签名证书
alert tls any any -> any any (
    msg:"SUSPICIOUS Self-signed certificate";
    tls.issuerdn;
    content:"CN=";
    tls.subject;
    content:"CN=";
    # issuer 和 subject 相同表示自签名
    sid:2001002;
)
```

---

## 3. SNI 检测

### 3.1 tls.sni 详解

SNI（Server Name Indication）允许客户端在 TLS 握手时指定目标服务器域名：

```snort
# 检测连接到特定域名
alert tls any any -> any any (
    msg:"MALWARE Connection to suspicious SNI";
    tls.sni;
    content:"c2.malware.com";
)
```

```
# TLS Client Hello 中的 SNI 扩展
Extension: server_name (len=17)
    Type: server_name (0)
    Length: 17
    Server Name Indication (SNI):
        Server Name Type: host_addr (0)
        Server Name Length: 14
        Server Name: c2.malware.com     <- tls.sni 匹配区域
```

### 3.2 tls.sni 源码解析

```c
// src/detect-tls-sni.c — SNI 检测
typedef struct DetectTlsSniData_ {
    uint8_t *sni;                 // SNI 值
    uint16_t sni_len;            // SNI 长度
    uint8_t flags;
#define TLS_SNI_RAW              0x01  // 原始匹配
} DetectTlsSniData;

static int DetectTlsSniSetup(char *optstr, Signature *sig)
{
    DetectTlsSniData *data = SCCalloc(1, sizeof(DetectTlsSniData));

    /* 解析 tls.sni; 选项 */
    if (strncmp(optstr, "tls.sni", 7) == 0) {
        if (strstr(optstr, ".raw") != NULL) {
            data->flags |= TLS_SNI_RAW;
        }
    }

    /* 查找 content 关键字 */
    DetectContentData *cd = GetLastContent(sig);
    if (cd == NULL) {
        SCLogError("tls.sni requires preceding content match");
        return -1;
    }

    cd->flags |= CONTENT_TLS_SNI;

    return 0;
}

static int DetectTlsSniMatch(SSLState *ssl_state, void *data)
{
    DetectTlsSniData *sni_data = (DetectTlsSniData *)data;

    /* 获取 SNI 值 */
    char *sni = ssl_state->sni;
    if (sni == NULL) {
        /* 尝试从 ClientHello 中提取 */
        sni = SSLExtractSNI(ssl_state->client_connp);
        if (sni == NULL) {
            return 0;
        }
    }

    /* 规范化 SNI */
    if (!(sni_data->flags & TLS_SNI_RAW)) {
        /* 转小写 */
        sni = StrToLower(sni);
    }

    /* 内容匹配 */
    int result = DetectContentMatch(sni, strlen(sni), sni_data);

    return result;
}
```

---

## 4. TLS 版本检测

### 4.1 tls.version 详解

```snort
# 检测 TLS 1.0/1.1（已废弃）
alert tls any any -> any any (
    msg:"TLS Obsolete version detected";
    tls.version;
    content:"0x0301";  # TLS 1.0
    # 或 content:"0x0302"; TLS 1.1
)

# 检测 SSLv3（极不安全）
alert tls any any -> any any (
    msg:"SSLv3 connection attempt";
    tls.version;
    content:"0x0300";
)
```

### 4.2 TLS 版本标识

| 版本    | 十六进制 | 说明     |
| :------ | :------: | :------- |
| SSL 3.0 |  0x0300  | 已废弃   |
| TLS 1.0 |  0x0301  | 已废弃   |
| TLS 1.1 |  0x0302  | 已废弃   |
| TLS 1.2 |  0x0303  | 当前推荐 |
| TLS 1.3 |  0x0304  | 最新标准 |

```c
// src/detect-tls-version.c — 版本检测
typedef struct DetectTlsVersionData_ {
    uint16_t version;             // 版本号
    const char *version_str;      // 版本字符串
} DetectTlsVersionData;

static int DetectTlsVersionMatch(SSLState *ssl_state, void *data)
{
    DetectTlsVersionData *ver_data = (DetectTlsVersionData *)data;

    /* 获取 TLS 版本 */
    uint16_t version = ssl_state->version;

    /* 版本比较 */
    if (ver_data->version == version) {
        return 1;
    }

    return 0;
}
```

---

## 5. 证书指纹检测

### 5.1 tls.fingerprint 详解

```snort
# 检测已知恶意证书
alert tls any any -> any any (
    msg:"MALWARE Known malicious certificate";
    tls.fingerprint;
    content:"sha1|aa:bb:cc:dd:ee:ff:...";
)
```

### 5.2 JA3/JA3S 指纹

JA3 是 TLS 客户端指纹，JA3S 是 TLS 服务端指纹：

```snort
# 检测特定客户端指纹
alert tls any any -> any any (
    msg:"MALWARE Emotet malware TLS fingerprint";
    tls.ja3;
    content:"769a3d57f2224c73";  # Emotet JA3
)

# 检测 Cobalt Strike 默认证书
alert tls any any -> any any (
    msg:"MALWARE Cobalt Strike C2 detected";
    tls.ja3s;
    content:"d41d8cd98f00b204e9800998ecf8427e";
)
```

### 5.3 指纹源码解析

```c
// src/app-layer-ssl.c — JA3 指纹计算
char *SSLComputeJA3(SSLState *ssl_state)
{
    /* JA3 字符串构建 */
    char ja3_str[512] = {0};

    /* TLS 版本 */
    snprintf(ja3_str, sizeof(ja3_str), "%02x", ssl_state->client_version);

    /* 加密算法套件 */
    for (int i = 0; i < ssl_state->client_ciphers_count; i++) {
        snprintf(ja3_str + strlen(ja3_str),
                 sizeof(ja3_str) - strlen(ja3_str),
                 ",%04x", ssl_state->client_ciphers[i]);
    }

    /* 扩展 */
    for (int i = 0; i < ssl_state->extensions_count; i++) {
        snprintf(ja3_str + strlen(ja3_str),
                 sizeof(ja3_str) - strlen(ja3_str),
                 ",%u", ssl_state->extensions[i]);
    }

    /* 计算 MD5 哈希 */
    return MD5Hash(ja3_str);
}

// src/detect-tls-ja3.c — JA3 检测
static int DetectTlsJa3Setup(char *optstr, Signature *sig)
{
    DetectTlsJa3Data *data = SCCalloc(1, sizeof(DetectTlsJa3Data));

    /* 解析 JA3 指纹 */
    const char *ja3_hash = ExtractHash(optstr);
    data->ja3_hash = SCStrdup(ja3_hash);

    return 0;
}

static int DetectTlsJa3Match(SSLState *ssl_state, void *data)
{
    DetectTlsJa3Data *ja3_data = (DetectTlsJa3Data *)data;

    /* 获取 JA3 指纹 */
    char *ja3 = ssl_state->ja3_hash;
    if (ja3 == NULL) {
        ja3 = SSLComputeJA3(ssl_state);
        ssl_state->ja3_hash = ja3;
    }

    /* 指纹比较 */
    return (strcmp(ja3, ja3_data->ja3_hash) == 0) ? 1 : 0;
}
```

---

## 6. TLS 会话检测

### 6.1 tls.session.resumed 详解

检测 TLS 会话恢复（会话复用）：

```snort
# 检测会话恢复（可能用于跟踪用户）
alert tls any any -> any any (
    msg:"TLS Session resumed";
    tls.session.resumed;
)
```

### 6.2 会话恢复机制

```
# 完整 TLS 握手
ClientHello  ------------------->
               <-------------------  ServerHello, Certificate, ServerHelloDone
ClientKeyExchange, Finished  --->
               <-------------------  Finished

# 会话恢复（ClientHello 包含 Session ID）
ClientHello (Session ID)  ---->
               <-------------------  ServerHello (same Session ID)
Finished  -------------------->
               <-------------------  Finished
```

```c
// src/detect-tls-session.c — 会话恢复检测
static int DetectTlsSessionResumedMatch(SSLState *ssl_state, void *data)
{
    /* 检查是否恢复的会话 */
    if (ssl_state->session_state == SSL_SESSION_RESUMED) {
        return 1;
    }
    return 0;
}
```

---

## 7. TLS 检测规则示例

### 7.1 恶意软件 C2 检测

```snort
# 检测已知恶意软件的 TLS 连接
alert tls any any -> any $EXTERNAL_NET 443 (
    msg:"MALWARE Known Trickbot C2";
    flow:to_server,established;
    tls.sni;
    content:"c2.trickbot.com";
    tls.version;
    content:"0x0303";  # TLS 1.2
    sid:2002001;
    rev:1;
)

# 检测 Cobalt Strike C2
alert tls any any -> any any (
    msg:"MALWARE Cobalt Strike beacon";
    flow:to_server,established;
    tls.ja3;
    content:"a0e2a44b26a03532c3b51e6d9d8c8d26";  # 常见 CS JA3
    sid:2002002;
    rev:1;
)
```

### 7.2 证书异常检测

```snort
# 检测自签名证书
alert tls any any -> any any (
    msg:"SUSPICIOUS Self-signed certificate detected";
    tls.issuerdn;
    content:"CN=";
    tls.subject;
    content:"CN=";
    # issuer 和 subject 相同
    sid:2003001;
    rev:1;
)

# 检测异常证书颁发者
alert tls any any -> any any (
    msg:"SUSPICIOUS Certificate issued by untrusted CA";
    tls.issuerdn;
    content:"CN=Let's Encrypt";
    # 但不是常见的合法域名
    not tls.subject;
    content:"letsencrypt.org";
    sid:2003002;
    rev:1;
)
```

### 7.3 数据泄露检测

```snort
# 检测上传到未认证服务器的敏感数据
alert tls any any -> any any (
    msg:"DATA Exfiltration via TLS";
    flow:to_server,established;
    tls.sni;
    content:"pastebin.com";
    tls.cert.issuer;
    content:"Cloudflare";
    file.data;
    content:"password=";
    threshold:type threshold, track by_src, count 5, seconds 60;
    sid:2004001;
    rev:1;
)
```

---

## 8. TLS 检测引擎集成

### 8.1 TLS 解析器注册

```c
// src/app-layer-ssl.c — TLS 协议注册
int SSLRegister(void)
{
    /* 注册协议 */
    AppLayerProtocol proto = {
        .name = "tls",
        .alproto = ALPROTO_TLS,
        .Register = TLSRegister,
        .Init = TLSInit,
        .Deinit = TLSDeinit,
    };

    AppLayerRegister(&proto);

    /* 注册关键字 */
    RegisterTlsSubject();
    RegisterTlsIssuerdn();
    RegisterTlsSni();
    RegisterTlsVersion();
    RegisterTlsFingerprint();
    RegisterTlsJa3();
    RegisterTlsJa3S();
    RegisterTlsSessionResumed();
    RegisterTlsCert();

    return 0;
}
```

### 8.2 TLS 状态结构

```c
// src/app-layer-ssl.h — TLS 状态
typedef struct SSLState_ {
    /* 连接信息 */
    uint8_t state;                // 握手状态
    uint16_t version;             // TLS 版本
    uint8_t flags;

    /* SNI */
    char *sni;                    // Server Name Indication
    bool sni_raw;                 // 原始 SNI

    /* 证书 */
    SSLCertsChain *client_certs;  // 客户端证书链
    SSLCertsChain *server_certs;  // 服务端证书链

    /* JA3 指纹 */
    char *ja3_hash;               // JA3 客户端指纹
    char *ja3s_hash;             // JA3S 服务端指纹

    /* 会话信息 */
    uint8_t session_state;        // 会话状态
    uint8_t *session_id;         // Session ID
    uint16_t session_id_len;

    /* 加密套件 */
    uint16_t *client_ciphers;
    uint16_t client_ciphers_count;

    /* 扩展 */
    SSLExtension *extensions;
    uint16_t extensions_count;

    /* 随机数 */
    uint8_t client_random[32];
    uint8_t server_random[32];
} SSLState;

/* 握手状态 */
typedef enum {
    TLS_STATE_ERROR = 0,
    TLS_STATE_CLIENT_HELLO,       // 等待 ClientHello
    TLS_STATE_SERVER_HELLO,       // 等待 ServerHello
    TLS_STATE_CERTIFICATE,        // 等待证书
    TLS_STATE_SERVER_KEY_EXCHANGE,// 等待密钥交换
    TLS_STATE_SERVER_HELLO_DONE,  // 等待 ServerHelloDone
    TLS_STATE_CLIENT_KEY_EXCHANGE,// 客户端密钥交换
    TLS_STATE_HANDSHAKE_DONE,     // 握手完成
    TLS_STATE_APPLICATION_DATA,  // 应用数据
} SSLStateEnum;
```

---

## 9. TLS 日志字段

### 9.1 EVE TLS 日志

```json
{
  "timestamp": "2026-04-15T10:30:00.123456Z",
  "event_type": "tls",
  "tls": {
    "subject": "CN=mail.google.com, O=Google LLC, L=Mountain View, ST=California, C=US",
    "issuerdn": "CN=GTS CA 1C3, O=Google Trust Services, C=US",
    "serial": "04:3A:2C:1D:7A:00:00:00:00:2E:7B",
    "fingerprint": "SHA1=AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:00:11:22:33",
    "sni": "mail.google.com",
    "version": "TLS 1.3",
    "ja3": "769a3d57f2224c73b6e35d57c2a5e6b5",
    "ja3s": "b32309a46a2e0f4e4e5a7d2f1c3b5a4",
    "client_certificates": [
      {
        "sha256": "3c6e0b8a0c0f0f4e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"
      }
    ],
    "server_certificates": [
      {
        "sha256": "a0e2a44b26a03532c3b51e6d9d8c8d26b32309a46a2e0f4e4e5a7d2f1c3b5a4"
      }
    ],
    "session_resumed": false
  }
}
```

### 9.2 TLS 日志配置

```yaml
# suricata.yaml
outputs:
  - eve-log:
      enabled: yes
      types:
        - tls:
            # 记录证书
            extended: yes
            # 记录证书链
            certs: yes
            # 记录原始字段
            raw: yes
            # 记录 JA3/JA3S
            ja3: yes
            ja3s: yes
```

---

## 10. 总结

Suricata 的 TLS 检测系统通过 `tls.*` 关键字体系提供了全面的 TLS/SSL 协议检测能力。`tls.subject` 和 `tls.issuerdn` 用于证书信息检测，`tls.sni` 用于 SNI 扩展检测，`tls.fingerprint` 和 `tls.ja3`/`tls.ja3s` 用于指纹检测，`tls.version` 用于版本检测。TLS 检测规则常用于识别恶意软件 C2 通信、自签名证书、过期 TLS 版本和证书异常等安全威胁。
