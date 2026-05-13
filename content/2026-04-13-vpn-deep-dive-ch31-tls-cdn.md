---
title: "VPN 技术深度探索 (三十一)：TLS 伪装与 CDN"
date: 2026-04-13
tags: [vpn, series, tls, cdn, domain-fronting, cloudflare, proxy]
description: "TLS 伪装与 CDN 技术深度解析——域前置（Domain Fronting）、SNI 隐藏、CDN 隐蔽、真实 TLS 证书、Cloudflare/Workers 部署与抗封锁架构"
---

> [!info] VPN 技术深度探索系列 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-vpn-deep-dive-ch30-clash|Clash 生态]]
> 2. **第三十一章：TLS 伪装与 CDN**
> 3. [[2026-04-13-vpn-deep-dive-ch32-tor-network|第三十二章：Tor 网络]]
> 4. [[2026-04-13-vpn-deep-dive-ch1-vpn-fundamentals|回到开头]]

---

## 1. 概述：TLS 伪装的重要性

TLS 伪装是翻墙技术的核心，其目标是**让翻墙流量看起来像正常的 HTTPS 流量**。GFW 无法（也不应该）阻断所有 TLS 流量，因此只要翻墙流量能完美伪装成正常 TLS，就能绕过审查。

```
TLS 伪装层次：

┌─────────────────────────────────────────────────────────────────┐
│                      TLS 伪装层级                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Level 0：无伪装（明文代理）                                      │
│  ├─ HTTP 代理                                                  │
│  └─ 极易被检测                                                │
│                                                                 │
│  Level 1：基础 TLS                                              │
│  ├─ 使用 TLS 加密                                              │
│  ├─ 自签名证书或固定 SNI                                        │
│  └─ 可被 SNI 检测                                              │
│                                                                 │
│  Level 2：真实 TLS                                              │
│  ├─ 使用真实 CA 签发的证书                                       │
│  ├─ SNI 与证书匹配                                            │
│  └─ 需要域名和证书基础设施                                       │
│                                                                 │
│  Level 3：CDN 隐蔽                                             │
│  ├─ 使用 CDN 作为中转                                          │
│  ├─ 隐藏真实服务器 IP                                          │
│  └─ CDN IP 通常不会被封锁                                      │
│                                                                 │
│  Level 4：域前置                                               │
│  ├─ SNI 与 Host 头不一致                                        │
│  ├─ CDN 支持才能实现                                           │
│  └─ GFW 无法看到真实目标                                        │
│                                                                 │
│  Level 5：完美伪装（Reality）                                   │
│  ├─ TLS 指纹完全模拟目标网站                                    │
│  ├─ 证书也伪装成目标网站                                        │
│  └─ 流量与访问目标网站无法区分                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. TLS 基础回顾

### 2.1 TLS 握手流程

```
TLS 1.2 握手流程：

┌─────────────────────────────────────────────────────────────────┐
│                      TLS 1.2 握手                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Client ──── ClientHello ────────────────────────────────────▶  │
│            │                                                   │
│            │ Version: TLS 1.2                                  │
│            │ Random: 32 bytes                                  │
│            │ Session ID: (可选)                                │
│            │ Cipher Suites: [...]                              │
│            │ Extensions:                                       │
│            │   + SNI (Server Name Indication)                 │
│            │   + ALPN                                         │
│            │   + ...                                          │
│            │                                                   │
│  Client ◀── ServerHello ──────────────────────────────────────  │
│            │                                                   │
│            │ Version: TLS 1.2                                 │
│            │ Random: 32 bytes                                  │
│            │ Session ID: ...                                  │
│            │ Cipher: TLS_AES_128_GCM_SHA256                  │
│            │                                                   │
│  Client ◀── Certificate ──────────────────────────────────────  │
│            │                                                   │
│            │ 证书链：                                          │
│            │ ├─ Server Certificate                            │
│            │ ├─ Intermediate CA                               │
│            │ └─ Root CA（通常省略）                            │
│            │                                                   │
│  Client ◀── ServerHelloDone ────────────────────────────────   │
│                                                                 │
│  Client ──── ClientKeyExchange ──────────────────────────────▶  │
│  Client ──── ChangeCipherSpec ──────────────────────────────▶  │
│  Client ──── Finished ──────────────────────────────────────▶  │
│                                                                 │
│  Client ◀── ChangeCipherSpec ────────────────────────────────  │
│  Client ◀── Finished ────────────────────────────────────────── │
│                                                                 │
│  应用数据加密传输                                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 TLS 1.3 改进

```
TLS 1.3 握手流程（简化）：

┌─────────────────────────────────────────────────────────────────┐
│                      TLS 1.3 握手                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1-RTT 握手：                                                   │
│                                                                 │
│  Client ──── ClientHello + Key Share ────────────────────────▶  │
│            │                                                   │
│            │ Version: TLS 1.3                                  │
│            │ Cipher Suites: TLS_AES_128_GCM_SHA256            │
│            │ Extensions:                                       │
│            │   + key_share: (客户端密钥)                       │
│            │   + supported_versions: TLS 1.3                   │
│            │   + SNI: (明文！)                                 │
│            │                                                   │
│  Client ◀── ServerHello + Key Share + Finished ───────────────  │
│                                                                 │
│  立即开始加密传输                                                │
│                                                                 │
│  问题：                                                         │
│  ├─ TLS 1.3 的 SNI 仍然是明文                                  │
│  ├─ ECH（Encrypted Client Hello）可解决但未普及                  │
│  └─ SNI 伪装仍然重要                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 SNI 详解

```
SNI（Server Name Indication）：

作用：在 TLS 握手时告诉服务器要访问哪个域名

位置：ClientHello 扩展

┌─────────────────────────────────────────────────────────────────┐
│                      SNI 扩展格式                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Extension: server_name (0x0000)                               │
│  Length: N                                                     │
│                                                                 │
│  ServerNameList:                                               │
│  ├─ Length: N-3                                               │
│  ├─ Name Type: host_name (0x00)                               │
│  ├─ Server Name Length: M                                     │
│  └─ Server Name: "example.com" (M bytes)                      │
│                                                                 │
│  重要：SNI 在 TLS 1.2 中完全明文                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

SNI 泄露场景：

用户访问被封锁网站时：
1. DNS 污染返回错误 IP（或被黑拦截）
2. TLS ClientHello 中的 SNI 暴露目标域名
3. GFW 识别到敏感 SNI
4. TCP RST 或连接中断

解决方案：
├─ 使用 CDN（CDN 的 SNI 不是敏感域名）
├─ 使用域前置（SNI 是 CDN 域名，Host 是真实目标）
└─ 使用 Reality（SNI 伪装成目标网站）
```

---

## 3. CDN 配合

### 3.1 CDN 工作原理

```
CDN（Content Delivery Network）：

┌─────────────────────────────────────────────────────────────────┐
│                      CDN 工作原理                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  无 CDN：                                                       │
│                                                                 │
│  Client ──────────────────────────▶ Server (真实 IP)            │
│              │                                                 │
│              └── GFW 可以封锁 Server IP                         │
│                                                                 │
│  有 CDN：                                                       │
│                                                                 │
│  Client ────▶ CDN Edge Node ────▶ Origin Server                 │
│              │                     │                            │
│              │                     └── 真实 IP 隐藏              │
│              │                                                  │
│              └── CDN IP 通常不被封锁                             │
│                                                                 │
│  CDN 优势：                                                     │
│  ├─ 隐藏真实服务器 IP                                           │
│  ├─ 全球分布式节点                                               │
│  ├─ 负载均衡和缓存                                              │
│  └─ DDoS 防护                                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 翻墙配合 CDN

```
翻墙服务 + CDN：

┌─────────────────────────────────────────────────────────────────┐
│                    CDN 配合架构                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Client ──▶ CDN ──▶ 翻墙服务器                                   │
│               │                                                 │
│               └── CDN IP（不被封锁）                              │
│                                                                 │
│  优点：                                                         │
│  ├─ 服务器 IP 隐藏                                              │
│  ├─ CDN 流量加密                                                │
│  ├─ 更难被封锁                                                  │
│  └─ 更好的全球性能                                              │
│                                                                 │
│  限制：                                                         │
│  ├─ 只支持 HTTP/2 + TLS                                         │
│  ├─ WebSocket 需要特殊配置                                      │
│  ├─ QUIC 可能不支持                                             │
│  └─ CDN 速度 限制                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 Cloudflare 配置

```
Cloudflare 作为 CDN：

配置步骤：

1. 注册 Cloudflare 账号
2. 添加域名，修改 NS 服务器
3. 在 Cloudflare 中设置：
   ├─ SSL/TLS: Full 或 Full (strict)
   ├─ TLS 版本: 1.2 minimum
   └─ 代理状态: DNS only → Proxied

4. 获取 Cloudflare Origin Certificate
   ├─ Cloudflare 签发给源站的免费证书
   └─ 在源站配置

5. 源站配置（翻墙服务器）：
   {
     "ssl": {
       "cert": "/path/to/origin-cert.pem",
       "key": "/path/to/origin-key.pem"
     }
   }

Cloudflare SSL 模式：
├─ Off: 无 SSL
├─ Flexible: 客户端到 CF 有 SSL，CF 到源站无 SSL
├─ Full: 双向 SSL，但证书不验证
└─ Full (strict): 双向 SSL + 证书验证（推荐）
```

---

## 4. 域前置（Domain Fronting）

### 4.1 域前置原理

**域前置（Domain Fronting）** 是一种利用 CDN 特性隐藏真实目标的技术：

```
域前置原理：

┌─────────────────────────────────────────────────────────────────┐
│                    域前置工作原理                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  普通 HTTPS：                                                   │
│  Client ──▶ TLS ClientHello                                    │
│            │                                                   │
│            │ SNI: example.com                                  │
│            │ Host: example.com                                  │
│            │                                                   │
│            └── GFW 看到访问 example.com                         │
│                                                                 │
│  域前置（HTTPS）：                                              │
│  Client ──▶ TLS ClientHello                                    │
│            │                                                   │
│            │ SNI: cdn-domain.com（CDN 域名）                    │
│            │ Host: blocked-site.com（真实目标）                  │
│            │                                                   │
│            └── GFW 只能看到 cdn-domain.com                       │
│                                                                 │
│  Cloudflare 域前置示例：                                         │
│  SNI: www.example.com（可访问的域名）                           │
│  Host: target-blocked-site.com（被封锁的域名）                   │
│                                                                 │
│  注意：                                                         │
│  ├─ 需要 CDN 支持                                              │
│  └─ Cloudflare 已禁用域前置（2018 年）                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 域前置的限制

```
域前置的消亡：

2018 年之前：
├─ Amazon CloudFront 支持
├─ Azure 支持
└─ 多家 CDN 支持

2018 年后：
├─ Cloudflare 禁用域前置
├─ Google 禁用域前置
├─ AWS CloudFront 禁用域前置
└─ 主要 CDN 都已禁用

原因：
├─ 被用于恶意软件通信
├─ 被用于绕过安全审查
└─ 监管压力

替代方案：
├─ 使用支持域前置的小型 CDN
├─ 使用自家 CDN（或 CDN 合作伙伴）
└─ Reality 协议（完全不需要域前置）
```

### 4.3 伪装域前置

```
伪装域前置（Disguised Domain Fronting）：

原理：
├─ SNI 使用正常域名
├─ Host 头使用被封锁域名
├─ CDN 根据 SNI 路由（不基于 Host）
└─ 服务器端通过其他方式识别真实目标

配置示例：

V2Ray VLESS + WebSocket + TLS：

服务端：
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/your-path"
      }
    }
  }]
}

客户端（使用 Cloudflare Workers 反向代理）：
├─ Worker 监听 cdn-domain.com/your-path
├─ 根据 path 路由到真实服务器
├─ Host 头被转发
└─ 真实目标隐藏在 path 中

效果：
├─ SNI = cdn-domain.com（正常域名）
├─ 流量到达 Cloudflare
├─ CF 根据 path 转发
└─ GFW 只能看到正常 CDN 流量
```

---

## 5. Cloudflare Workers 部署

### 5.1 Workers 架构

Cloudflare Workers 是边缘计算平台，可以部署反向代理：

```
Cloudflare Workers：

┌─────────────────────────────────────────────────────────────────┐
│                    Workers 架构                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Worker 脚本运行在 Cloudflare 全球边缘                            │
│                                                                 │
│  Client ──▶ CF Edge ──▶ Worker ──▶ Origin Server              │
│               │                                                 │
│               ├── 静态资源 ──直接返回                            │
│               │                                                 │
│               └── /path ──> Worker 脚本处理                      │
│                             │                                   │
│                             ├── 反向代理到 Origin               │
│                             └── WebSocket 升级                  │
│                                                                 │
│  限制：                                                         │
│  ├─ Worker 请求到 Origin 必须使用 CF 支持的协议                   │
│  ├─ 超时限制（CPU 时间 50ms，Wall time 30s）                     │
│  └─ 免费版每天 100,000 请求                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Workers 反向代理

```
Workers 代理配置：

// worker.js
addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request))
})

async function handleRequest(request) {
  const url = new URL(request.url)

  // 只代理特定 path
  if (url.pathname.startsWith('/proxy/')) {
    // 提取目标
    const targetPath = url.pathname.replace('/proxy/', '/')
    const targetUrl = 'https://your-origin-server.com' + targetPath

    // 转发请求
    const modifiedRequest = new Request(targetUrl, {
      method: request.method,
      headers: request.headers,
      body: request.body
    })

    return fetch(modifiedRequest)
  }

  // 其他请求返回简单页面
  return new Response('OK', { status: 200 })
}
```

### 5.3 V2Ray + Workers 部署

```
V2Ray + Cloudflare Workers 部署：

架构：
Client ──▶ CF Worker ──▶ V2Ray Server

Worker 配置（proxy.js）：
const serverHost = 'your-v2ray-server.com'

addEventListener('fetch', event => {
  event.respondWith(handleRequest(event.request))
})

async function handleRequest(request) {
  const url = new URL(request.url)

  // WebSocket 升级
  if (request.headers.get('Upgrade') === 'websocket') {
    const target = 'wss://' + serverHost
    return fetch(target, {
      cf: { connectTimeout: 60 },
      headers: request.headers,
      body: request.body
    })
  }

  // HTTP 代理
  const targetUrl = 'https://' + serverHost + url.pathname
  return fetch(targetUrl, {
    cf: { connectTimeout: 60 },
    headers: request.headers,
    body: request.body
  })
}

V2Ray 服务端配置：
{
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/your-path"
      }
    }
  }]
}
```

---

## 6. 真实 TLS 证书

### 6.1 证书类型选择

```
翻墙服务的证书选择：

┌─────────────────────────────────────────────────────────────────┐
│                      证书类型对比                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 自签名证书：                                                │
│     ├─ 自己生成，无需购买                                       │
│     ├─ 客户端需要信任证书                                        │
│     └─ 不推荐，易被检测                                         │
│                                                                 │
│  2. Let's Encrypt（免费）：                                     │
│     ├─ 免费、自动续期                                           │
│     ├─ CA 受信任                                               │
│     └─ 推荐使用                                                 │
│                                                                 │
│  3. 商业证书：                                                  │
│     ├─ DigiCert, GlobalSign 等                                 │
│     ├─ 更长有效期                                              │
│     └─ 成本较高                                                 │
│                                                                 │
│  4. CDN 证书：                                                  │
│     ├─ Cloudflare Origin Certificate                           │
│     ├─ 免费                                                    │
│     └─ 仅 Cloudflare CDN 使用                                  │
│                                                                 │
│  5. 伪装目标证书（Reality）：                                   │
│     ├─ 使用目标网站的真实证书                                    │
│     ├─ 完美伪装                                                │
│     └─ 需要目标网站配合或特殊获取                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Let's Encrypt 配置

```
Let's Encrypt + Nginx + V2Ray：

1. 安装 Certbot：
   apt update
   apt install certbot python3-certbot-nginx

2. 获取证书（DNS 验证）：
   certbot certonly --nginx -d your-domain.com

3. Nginx 配置（用于 Let's Encrypt 验证）：
   server {
       listen 80;
       server_name your-domain.com;
       location /.well-known/acme-challenge/ {
           root /var/www/certbot;
       }
   }

4. Nginx + V2Ray 共存：
   server {
       listen 443 ssl;
       server_name your-domain.com;

       ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
       ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;

       # V2Ray WebSocket 路径
       location /vless {
           proxy_pass http://127.0.0.1:10086;
           proxy_http_version 1.1;
           proxy_set_header Upgrade $http_upgrade;
           proxy_set_header Connection "upgrade";
           proxy_set_header Host $host;
       }

       # 其他路径返回正常页面
       location / {
           root /var/www/html;
       }
   }

5. 自动续期：
   crontab -e
   # 每天凌晨 3 点检查续期
   0 3 * * * certbot renew --quiet
```

---

## 7. TLS 指纹与 uTLS

### 7.1 TLS 指纹原理

TLS ClientHello 中的密码套件顺序、扩展等会形成独特的"指纹"：

```
TLS 指纹：

JA3/JA3S 指纹：
├─ JA3：客户端指纹
├─ JA3S：服务器指纹
└─ 用于识别客户端/服务器类型

常见浏览器的 JA3：
Chrome:    a8ff3a8bf2eb2a3bc9a8b4eb8b6f8c66
Firefox:   95a9e0cc2a0d9e1b1c1e0e1f2d3c4b5a
Safari:    777e2d5c493c1e1f2d3c4b5a6e7f8g9

翻墙工具的 JA3：
├─ Go TLS 库：固定的指纹
├─ 原版 V2Ray：独特的指纹
└─ 使用 uTLS 模拟：与浏览器相同

GFW 检测方式：
├─ 记录常见翻墙工具的 JA3
├─ 识别非浏览器 JA3
└─ 阻断异常指纹的连接
```

### 7.2 uTLS 库

```
uTLS（TLS 指纹模拟）：

Xray/Clash.Meta 支持 uTLS：

Reality 配置中使用：
{
  "realitySettings": {
    "fingerprint": "chrome"  // 模拟 Chrome 指纹
  }
}

支持指纹：
├─ chrome
├─ firefox
├─ safari
├─ ios
├─ android
└─ random（随机选择）

效果：
├─ JA3 与真实浏览器一致
├─ GFW 无法通过指纹识别
└─ 需要持续更新指纹库
```

---

## 8. 抗封锁架构设计

### 8.1 多层防御架构

```
抗封锁架构：

┌─────────────────────────────────────────────────────────────────┐
│                      多层防御架构                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Layer 1: CDN 隐蔽                                             │
│  ├─ 真实 IP 隐藏在 CDN 后面                                     │
│  └─ CDN IP 通常不被封锁                                         │
│                                                                 │
│  Layer 2: TLS 伪装                                             │
│  ├─ 使用真实 TLS 证书                                           │
│  ├─ SNI 使用正常域名                                            │
│  └─ 配合 uTLS 模拟浏览器指纹                                     │
│                                                                 │
│  Layer 3: 协议伪装                                             │
│  ├─ 使用 VLESS/Trojan 等协议                                   │
│  ├─ WebSocket 或 gRPC 传输                                      │
│  └─ 协议头完全加密                                              │
│                                                                 │
│  Layer 4: 域名分流                                             │
│  ├─ 国内域名直连                                                │
│  ├─ 敏感域名走代理                                              │
│  └─ 减少代理流量                                                │
│                                                                 │
│  Layer 5: 多节点冗余                                           │
│  ├─ 准备多个服务器                                             │
│  ├─ 自动故障转移                                               │
│  └─ 订阅制管理节点                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 8.2 快速恢复方案

```
封锁后的快速恢复：

1. DNS 预热：
   ├─ 准备多个备用域名
   ├─ 使用 DNSSEC
   └─ 快速切换 DNS

2. IP 池管理：
   ├─ 准备多个 IP
   ├─ 使用 AS 多样性
   └─ 定期轮换

3. 域名池：
   ├─ 注册多个相似域名
   ├─ 使用不同注册商
   └─ 分散风险

4. 自动化切换：
   ├─ 监控节点可用性
   ├─ 自动切换到备用节点
   └─ 用户无感知

方案对比：
┌─────────────────────────────────────────────────────────────────┐
│                        方案对比                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  方案              │ 成本    │ 复杂度  │ 抗封锁能力               │
│  ─────────────────┼─────────┼─────────┼───────────────          │
│  单节点            │ 低      │ 低      │ 弱                      │
│  多节点            │ 中      │ 中      │ 中                      │
│  CDN + Workers    │ 低      │ 中      │ 强                      │
│  Reality          │ 低      │ 中      │ 很强                    │
│  多层混合          │ 高      │ 高      │ 最强                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 9. 总结

```
TLS 伪装与 CDN 核心要点：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  TLS 伪装层级：                                                 │
│  ├─ Level 0：无伪装（明文）                                      │
│  ├─ Level 1：基础 TLS                                          │
│  ├─ Level 2：真实 TLS + CA 证书                                 │
│  ├─ Level 3：CDN 隐蔽                                          │
│  ├─ Level 4：域前置（大部分 CDN 已禁用）                        │
│  └─ Level 5：Reality 完美伪装                                   │
│                                                                 │
│  CDN 配合：                                                     │
│  ├─ 隐藏真实服务器 IP                                           │
│  ├─ 提供全球分布式入口                                          │
│  ├─ 流量加密 + 加速                                            │
│  └─ Cloudflare Workers 可部署反向代理                           │
│                                                                 │
│  证书选择：                                                     │
│  ├─ Let's Encrypt（推荐，免费自动）                             │
│  ├─ Cloudflare Origin（配合 CF CDN）                           │
│  └─ Reality 使用目标网站证书                                    │
│                                                                 │
│  抗封锁最佳实践：                                               │
│  ├─ CDN + TLS + 协议伪装多层叠加                               │
│  ├─ uTLS 模拟真实浏览器指纹                                     │
│  ├─ 多节点冗余 + 自动故障转移                                  │
│  └─ Reality 协议作为最高安全选项                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

TLS 伪装和 CDN 配合是现代翻墙技术的核心。通过合理利用 CDN 的特性和 TLS 协议，可以构建难以被检测和封锁的翻墙方案。Reality 协议代表了这一领域的最新进展，提供了接近完美的流量伪装能力。

---

## 参考资料

1. IETF. "Transport Layer Security (TLS) Protocol Version 1.3." RFC 8446.
2. Cloudflare. "Cloudflare Workers Documentation."
3. RPRX. "XTLS Vision and Reality Protocol."
4. Let's Encrypt. "Documentation."
