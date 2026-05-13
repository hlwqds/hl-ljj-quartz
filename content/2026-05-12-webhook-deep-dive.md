---
title: Webhook 深度解析：从协议原理到生产实践
date: 2026-05-12 18:00:00
tags: [Webhook, HTTP, Security, Event-Driven, Integration, HMAC, Pub/Sub, API, Stripe, GitHub]
description: 深入解析 Webhook 协议——HTTP 回调机制、签名验证、安全传输、重试策略、Fan-out 分发、幂等性处理，以及 GitHub/Stripe/Slack 主流平台的实现差异与生产部署架构。
---

# Webhook 深度解析：从协议原理到生产实践

## 1. 概述

```
本文目标：

解析 Webhook 技术的核心原理、生产实践、以及与 Code Agent 的集成。

内容结构：
  1. Webhook 是什么（历史 / 与 polling / WebSocket 对比）
  2. 协议细节（HTTP POST / Headers / Body 格式）
  3. 签名验证（HMAC-SHA256 / 时间戳 / 重放攻击防御）
  4. 安全传输（TLS / 证书验证 / IP 白名单）
  5. 可靠性设计（幂等性 / 重试机制 / 消息顺序）
  6. 架构模式（Fan-out / 消息过滤 / 优先级队列）
  7. 主流平台实现（GitHub / Stripe / Slack / 自建）
  8. 调试与测试（CLI 工具 / 本地调试 / 抓包）
  9. 规模与性能（高吞吐 / 限流 / 背压）
  10. Hermes Webhook Subscriptions 实战

读者假设：
  · 有网络基础（HTTP / TLS / TCP）
  · 了解基本的安全概念（HMAC / 签名）
  · 有 API 集成经验
```

---

## 2. 什么是 Webhook

### 2.1 定义与历史

```
Webhook 是什么？

┌──────────────────────────────────────────────────────────────────────┐
│                        Webhook 定义                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Webhook = HTTP 回调                                                │
│   = 服务端主动向客户端推送数据的机制                                  │
│   = 反向 API（Reverse API）                                         │
│                                                                      │
│   核心思想：                                                         │
│   · 客户端注册一个 HTTP URL                                          │
│   · 服务端在事件发生时主动 POST 到这个 URL                           │
│   · 客户端处理请求并返回响应                                          │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

历史：
  · 2005 年左右：Salesforce 首次引入 "Outbound Messages"
  · 2007 年：GitHub 引入 Webhook，成为行业标准
  · 2010 年后：Stripe 标准化了 Webhook 签名验证
  · 2020 年后：几乎所有 SaaS 平台都支持 Webhook
```

### 2.2 与其他通信模式对比

```
通信模式对比：

┌──────────────────────────────────────────────────────────────────────┐
│                        通信模式对比                                  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. Polling (轮询)                                                 │
│      ┌──────────────────────────────────────────────────────────┐   │
│      │  Client ──► GET /api/events ──► Server                    │   │
│      │            ◄── 200 OK: [] ───                            │   │
│      │                 (无新事件)                                │   │
│      │                 ◄── 200 OK: [e1, e2] ─── (有事件)      │   │
│      └──────────────────────────────────────────────────────────┘   │
│      缺点：延迟高、资源浪费、扩展性差                                  │
│                                                                      │
│   2. WebSocket (双向)                                               │
│      ┌──────────────────────────────────────────────────────────┐   │
│      │  Client ◄═══ WebSocket ═══► Server                      │   │
│      │         (持久连接，双向通信)                              │   │
│      └──────────────────────────────────────────────────────────┘   │
│      优点：延迟极低、双向通信                                        │
│      缺点：复杂、需要维护连接状态、协议开销                           │
│                                                                      │
│   3. Webhook (服务端推送)                                           │
│      ┌──────────────────────────────────────────────────────────┐   │
│      │  Client ──► POST /webhook ──► Server                    │   │
│      │  (注册URL)        (事件触发)                              │   │
│      └──────────────────────────────────────────────────────────┘   │
│      优点：实时、简单、标准化                                        │
│      缺点：需要公网可达、依赖 HTTP                                  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

| 特性     | Polling            | WebSocket            | Webhook       |
| -------- | ------------------ | -------------------- | ------------- |
| 延迟     | 高 (秒-分钟)       | 极低 (毫秒)          | 低 (秒)       |
| 复杂度   | 低                 | 高                   | 低            |
| 资源消耗 | 高 (频繁轮询)      | 中 (持久连接)        | 低 (按需)     |
| 双向通信 | 否                 | 是                   | 否            |
| 断线重连 | N/A                | 需要                 | 自动 (重试)   |
| 扩展性   | 差                 | 中                   | 好            |
| 公网需求 | 否                 | 否                   | 是            |
| 适用场景 | 低频、低实时性需求 | 聊天、游戏，金十数据 | SaaS 事件通知 |

### 2.3 Webhook 的工作流程

```
Webhook 完整工作流程：

┌──────────────────────────────────────────────────────────────────────┐
│                     Webhook 工作流程                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. 注册阶段                                                        │
│      Client ──► POST /webhooks ──► Server                           │
│        │              (注册URL + 事件类型)                          │
│        ◄── 201 Created: {webhook_id, secret} ───                   │
│                                                                      │
│   2. 事件触发                                                        │
│      事件源 ──► 业务逻辑 ──► Webhook Engine                          │
│                                                                      │
│   3. 发送阶段                                                        │
│      Server ──► POST https://client.com/webhook                      │
│        │         + HMAC-SHA256 signature                           │
│        │         + X-Webhook-ID / X-Event-Type                     │
│        │         + Timestamp                                        │
│        ◄── 200 OK ───                                              │
│                                                                      │
│   4. 处理阶段                                                        │
│      Client ──► 验证签名 ──► 解析 payload ──► 执行业务逻辑          │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 3. HTTP 协议细节

### 3.1 请求格式

```
Webhook HTTP 请求结构：

┌──────────────────────────────────────────────────────────────────────┐
│                        HTTP POST 请求                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   POST /webhook HTTP/1.1                                            │
│   Host: example.com                                                │
│   Content-Type: application/json                                    │
│   User-Agent: GitHub-Hookshot/xxx                                   │
│   Delivery-ID: 72d1e3f-0001-0001-0001-7631ab3dce00                 │
│   X-Webhook-ID: webhook_12345                                      │
│   X-Webhook-Event: push                                            │
│   X-Webhook-Signature-256: sha256=abc123...                       │
│   X-GitHub-Event: push                                             │
│   X-GitHub-Delivery: 72d1e3f-...                                   │
│   X-Hub-Signature-256: sha256=abc123...                          │
│   Content-Length: 1234                                             │
│                                                                      │
│   {                                                                │
│     "ref": "refs/heads/main",                                      │
│     "before": "abc123",                                            │
│     "after": "def456",                                             │
│     "repository": { ... },                                         │
│     "pusher": { ... },                                             │
│     "commits": [ ... ]                                             │
│   }                                                                │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

关键 Header 说明：

  ┌────────────────────────────────────────────────────────────────┐
  │  Header                    │  说明                              │
  │  ──────────────────────────┼───────────────────────────────────│
  │  Content-Type              │  通常 application/json            │
  │  User-Agent                │  发送方标识 (GitHub-Hookshot/xxx) │
  │  X-Webhook-ID              │  Webhook 实例 ID                  │
  │  X-Webhook-Event           │  事件类型 (push/pull_request)     │
  │  X-Webhook-Signature-256   │  HMAC-SHA256 签名                 │
  │  X-Hub-Signature-256      │  GitHub 专用签名 header           │
  │  X-GitHub-Event            │  GitHub 事件类型                  │
  │  X-GitHub-Delivery         │  GitHub 投递 ID (用于幂等)         │
  │  X-Stripe-Signature        │  Stripe 签名 (带时间戳)           │
  │  Content-Length            │  Body 长度                        │
  └────────────────────────────────────────────────────────────────┘
```

### 3.2 响应格式与超时

```
Webhook 响应要求：

┌──────────────────────────────────────────────────────────────────────┐
│                        HTTP 响应                                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   期望的响应码：                                                     │
│   · 2xx: 成功接收                                                   │
│   · 301/302: 重定向 (不推荐，浪费资源)                               │
│   · 4xx: 客户端错误 (签名错误/无权限)                                │
│   · 5xx: 服务端错误 (会触发重试)                                    │
│                                                                      │
│   常见响应码：                                                       │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  200 OK           │  标准成功                               │     │
│   │  202 Accepted     │  已接收，处理异步进行                   │     │
│   │  204 No Content   │  成功，无需返回 body                    │     │
│   │  400 Bad Request  │  格式错误                               │     │
│   │  401 Unauthorized │  签名验证失败                          │     │
│   │  403 Forbidden    │  无权限                               │     │
│   │  429 Too Many Req  │  限流                                 │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   超时设置：                                                         │
│   · 默认超时: 30 秒                                                 │
│   · Stripe: 300 秒 (可配置)                                        │
│   · GitHub: 30 秒                                                  │
│   · 超时 → 重试                                                     │
│                                                                      │
│   响应 Body：                                                       │
│   · 建议返回 JSON { "received": true }                             │
│   · 不要返回大 body (> 1MB)                                        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 3.3 主流平台 Header 差异

```
平台 Header 对比：

┌──────────────────────────────────────────────────────────────────────┐
│                   主流平台 Webhook Header                           │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   GitHub:                                                          │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  X-GitHub-Event: push                                      │     │
│   │  X-GitHub-Delivery: 72d1e3f-0001-0001-0001-7631ab3dce00   │     │
│   │  X-Hub-Signature-256: sha256=abc123...                    │     │
│   │  User-Agent: GitHub-Hookshot/xxx                          │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   Stripe:                                                          │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  Stripe-Signature: t=1234567890,v1=abc123...              │     │
│   │  Content-Type: application/json                            │     │
│   │  User-Agent: Stripe/1.0                                    │     │
│   └────────────────────────────────────────────────────────────┘     │
│   特点: 签名包含时间戳 (t=)，用于重放攻击防御                         │
│                                                                      │
│   Slack:                                                          │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  X-Slack-Retry-Num: 1                                      │     │
│   │  X-Slack-Retry-Reason: http_200                          │     │
│   │  X-Slack-Signature: v0=abc123...                           │     │
│   │  Content-Type: application/x-www-form-urlencoded          │     │
│   └────────────────────────────────────────────────────────────┘     │
│   特点: 使用 app-level signing secret，非 per-webhook               │
│                                                                      │
│   自建 Webhook (建议):                                              │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  X-Webhook-ID: wh_abc123                                   │     │
│   │  X-Webhook-Event: order.created                           │     │
│   │  X-Webhook-Signature: sha256=abc123...                     │     │
│   │  X-Webhook-Timestamp: 1234567890                           │     │
│   │  Content-Type: application/json                            │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 4. 签名验证

### 4.1 为什么需要签名验证

```
签名验证的目的：

┌──────────────────────────────────────────────────────────────────────┐
│                        安全威胁                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. 伪造攻击                                                        │
│      攻击者猜测 Webhook URL，发送伪造事件                             │
│      "有人在 GitHub 上给你提交了 PR" → 其实是假的                    │
│                                                                      │
│   2. 重放攻击                                                        │
│      攻击者截获合法请求，重复发送                                     │
│      "你的账号又被扣了 100 美元" → 同一个事件重复处理                │
│                                                                      │
│   3. 中间人攻击                                                       │
│      不安全 HTTP 传输时被截获                                         │
│      → 解决方案：强制 HTTPS                                         │
│                                                                      │
│   4. 消息篡改                                                        │
│      请求被修改后发送                                                │
│      "转账金额改为 10000" → 篡改金额字段                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.2 HMAC-SHA256 签名原理

```
HMAC-SHA256 签名流程：

┌──────────────────────────────────────────────────────────────────────┐
│                        签名生成                                     │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   发送方 (Webhook Provider):                                        │
│                                                                      │
│   payload = '{"event": "payment", "amount": 100}'                  │
│   secret  = "whsec_abc123def456"                                   │
│                                                                      │
│   signature = HMAC-SHA256(secret, payload)                        │
│             = "sha256=72d1e3f1a2b3c4d5e6f7..."                     │
│                                                                      │
│   HTTP Header:                                                     │
│   X-Webhook-Signature: sha256=72d1e3f1a2b3c4d5e6f7...              │
│                                                                      │
│   接收方 (Client):                                                  │
│                                                                      │
│   1. 从 header 获取 signature                                       │
│   2. 用同样的 secret 计算 expected_signature                         │
│   3. 对比两者 (timing-safe comparison)                               │
│   4. 一致则验证通过                                                  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 4.3 签名验证代码实现

```python
# Python 签名验证实现
import hmac
import hashlib
import time
import os

class WebhookVerifier:
    """通用 Webhook 签名验证器"""

    def __init__(self, secret: str, tolerance: int = 300):
        """
        Args:
            secret: Webhook 密钥
            tolerance: 时间戳容差（秒），用于防止重放攻击
        """
        self.secret = secret.encode('utf-8')
        self.tolerance = tolerance

    def verify_sha256(self, payload: bytes, signature: str) -> bool:
        """
        验证 SHA256 签名

        Args:
            payload:原始请求 body
            signature: header 中的签名 (sha256=xxx)

        Returns:
            是否验证通过
        """
        if not signature.startswith('sha256='):
            return False

        expected = hmac.new(
            self.secret,
            payload,
            hashlib.sha256
        ).hexdigest()

        actual = signature[7:]  # 去掉 "sha256=" 前缀

        # timing-safe 比较，防止时序攻击
        return hmac.compare_digest(expected, actual)

    def verify_with_timestamp(self, payload: bytes, header: str) -> bool:
        """
        验证带时间戳的签名 (Stripe 模式)

        Stripe-Signature: t=1234567890,v1=abc123...

        重放攻击防御：时间戳超过 tolerance 则拒绝
        """
        parts = dict(p.split('=', 1) for p in header.split(','))
        timestamp = parts.get('t')
        signature = parts.get('v1')

        if not timestamp or not signature:
            return False

        # 时间戳检查 (防止重放)
        ts = int(timestamp)
        now = int(time.time())
        if abs(now - ts) > self.tolerance:
            return False  # 太旧或太新的请求

        # 计算带时间戳的签名
        signed_payload = f"{timestamp}.{payload.decode('utf-8')}"
        expected = hmac.new(
            self.secret,
            signed_payload.encode('utf-8'),
            hashlib.sha256
        ).hexdigest()

        return hmac.compare_digest(expected, signature)

    def generate_signature(self, payload: bytes) -> str:
        """生成签名 (用于测试)"""
        return 'sha256=' + hmac.new(
            self.secret,
            payload,
            hashlib.sha256
        ).hexdigest()
```

```typescript
// TypeScript 签名验证实现
import crypto from "crypto"

interface VerifyOptions {
  secret: string
  timestampTolerance?: number // 秒
}

class WebhookVerifierTS {
  private secret: Buffer
  private timestampTolerance: number

  constructor(options: VerifyOptions) {
    this.secret = Buffer.from(options.secret, "utf-8")
    this.timestampTolerance = options.timestampTolerance ?? 300
  }

  verify(payload: Buffer, header: string): boolean {
    if (header.startsWith("sha256=")) {
      return this.verifySha256(payload, header)
    } else if (header.includes(",")) {
      return this.verifyWithTimestamp(payload, header)
    }
    return false
  }

  private verifySha256(payload: Buffer, header: string): boolean {
    const signature = header.slice(7) // 去掉 "sha256="
    const expected = crypto.createHmac("sha256", this.secret).update(payload).digest("hex")
    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))
  }

  private verifyWithTimestamp(payload: Buffer, header: string): boolean {
    const parts = header.split(",").reduce(
      (acc, p) => {
        const [k, v] = p.split("=", 2)
        acc[k.trim()] = v.trim()
        return acc
      },
      {} as Record<string, string>,
    )

    const timestamp = parseInt(parts["t"], 10)
    const signature = parts["v1"]

    if (!timestamp || !signature) return false

    // 重放攻击检查
    const now = Math.floor(Date.now() / 1000)
    if (Math.abs(now - timestamp) > this.timestampTolerance) {
      return false
    }

    // Stripe 签名格式: HMAC-SHA256(timestamp + "." + payload)
    const signedPayload = `${timestamp}.${payload.toString("utf-8")}`
    const expected = crypto
      .createHmac("sha256", this.secret)
      .update(signedPayload, "utf-8")
      .digest("hex")

    return crypto.timingSafeEqual(Buffer.from(signature), Buffer.from(expected))
  }
}
```

### 4.4 各平台签名算法对比

```
签名算法对比：

┌──────────────────────────────────────────────────────────────────────┐
│                   平台签名算法对比                                   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   GitHub:                                                          │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  Algorithm: HMAC-SHA256                                    │     │
│   │  Format:    X-Hub-Signature-256: sha256=<hex>              │     │
│   │  Signed:    raw request body                               │     │
│   │  Secret:    per-webhook secret                             │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   Stripe:                                                         │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  Algorithm: HMAC-SHA256                                    │     │
│   │  Format:    Stripe-Signature: t=<ts>,v1=<sig>              │     │
│   │  Signed:    "<timestamp>.<payload>"                        │     │
│   │  Secret:    webhook signing secret (whsec_...)            │     │
│   │  特点:      带时间戳，防止重放攻击                           │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   Slack:                                                          │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  Algorithm: HMAC-SHA256                                    │     │
│   │  Format:    X-Slack-Signature: v0=<sig>                    │     │
│   │  Signed:    "v0:<timestamp>.<body>"                        │     │
│   │  Secret:    app-level signing secret                      │     │
│   │  特点:      Slack 会自动添加 X-Slack-Signature             │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   自建 Webhook (推荐):                                              │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  Algorithm: HMAC-SHA256                                    │     │
│   │  Format:    X-Webhook-Signature: sha256=<hex>              │     │
│   │  Signed:    "<timestamp>.<raw_body>" (推荐)               │     │
│   │            OR raw_body (简单但不防重放)                    │     │
│   │  Secret:    per-subscription secret                       │     │
│   │  Header:    X-Webhook-Timestamp: <unix_ts>                │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 5. 可靠性设计

### 5.1 重试机制

```
Webhook 重试策略：

┌──────────────────────────────────────────────────────────────────────┐
│                        重试机制                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   服务端重试触发条件：                                               │
│   · HTTP 5xx 响应                                                   │
│   · 连接超时 / 网络错误                                              │
│   · 客户端无响应                                                     │
│                                                                      │
│   服务端不重试条件：                                                 │
│   · HTTP 2xx/3xx/4xx (除 429)                                       │
│   · 签名验证失败 (401/403)                                          │
│                                                                      │
│   典型重试间隔 (指数退避):                                           │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  重试次数  │  GitHub    │  Stripe    │  自建 (建议)        │     │
│   │  ──────────┼────────────┼────────────┼────────────────────│     │
│   │  1         │  10 秒      │  1 分钟    │  30 秒             │     │
│   │  2         │  1 分钟     │  5 分钟    │  2 分钟            │     │
│   │  3         │  5 分钟     │  30 分钟   │  10 分钟           │     │
│   │  4         │  30 分钟    │  2 小时    │  1 小时            │     │
│   │  5         │  2 小时     │  24 小时   │  24 小时 (最终)    │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   最大重试次数：                                                     │
│   · GitHub: 无限重试直到成功                                         │
│   · Stripe: 72 小时内无限重试                                       │
│   · 自建: 建议设置最大重试次数 (如 10 次)                            │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 5.2 幂等性处理

```
幂等性设计：

┌──────────────────────────────────────────────────────────────────────┐
│                        幂等性                                        │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   为什么重要？                                                       │
│   · Webhook 可能重复投递 (网络问题 / 重试机制)                       │
│   · 同一事件被多次处理不应导致副作用                                 │
│                                                                      │
│   幂等 Key：                                                         │
│   · GitHub: X-GitHub-Delivery (UUID)                                │
│   · Stripe: 事件 ID (evt_xxx)                                       │
│   · 自建: X-Webhook-ID + X-Webhook-Timestamp                        │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

```python
# 幂等性处理示例
import sqlite3
from datetime import datetime, timedelta

class IdempotencyStore:
    """幂等性存储 (使用 SQLite)"""

    def __init__(self, db_path: str = "webhook_events.db"):
        self.conn = sqlite3.connect(db_path, check_same_thread=False)
        self._create_table()

    def _create_table(self):
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS processed_events (
                event_id TEXT PRIMARY KEY,     -- 幂等 Key
                event_type TEXT,               -- 事件类型
                payload_hash TEXT,              -- payload hash (额外校验)
                processed_at TIMESTAMP,         -- 处理时间
                result TEXT                    -- 处理结果
            )
        """)

        # 定期清理过期记录 (保留 7 天)
        self.conn.execute("""
            DELETE FROM processed_events
            WHERE processed_at < datetime('now', '-7 days')
        """)
        self.conn.commit()

    def is_processed(self, event_id: str) -> bool:
        """检查事件是否已处理"""
        cursor = self.conn.execute(
            "SELECT 1 FROM processed_events WHERE event_id = ?",
            (event_id,)
        )
        return cursor.fetchone() is not None

    def mark_processed(self, event_id: str, event_type: str,
                       payload: bytes, result: str):
        """标记事件已处理"""
        import hashlib
        payload_hash = hashlib.sha256(payload).hexdigest()
        self.conn.execute("""
            INSERT OR IGNORE INTO processed_events
            (event_id, event_type, payload_hash, processed_at, result)
            VALUES (?, ?, ?, datetime('now'), ?)
        """, (event_id, event_type, payload_hash, result))
        self.conn.commit()

    def process(self, event_id: str, event_type: str,
                payload: bytes, handler):
        """
        幂等处理包装器

        Args:
            event_id: 事件唯一 ID
            event_type: 事件类型
            payload: 原始 payload
            handler: 处理函数 (接收 payload)

        Returns:
            处理结果 或 None (已处理过)
        """
        if self.is_processed(event_id):
            return None  # 跳过

        result = handler(payload)
        self.mark_processed(event_id, event_type, payload, result)
        return result
```

### 5.3 消息顺序与一致性

```
消息顺序问题：

┌──────────────────────────────────────────────────────────────────────┐
│                        顺序问题                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   问题：Webhook 可能不按事件顺序到达                                 │
│   例子：GitHub 的 push 事件，A 早于 B 发出，但 B 先到达              │
│                                                                      │
│   解决方案：                                                         │
│                                                                      │
│   1. 事件中的序列号/时间戳                                           │
│      event = {                                                       │
│        "id": "1234567890",      -- 唯一 ID                          │
│        "sequence": 42,          -- 序列号                            │
│        "timestamp": "2026-01-01T00:00:00Z"  -- 时间戳               │
│      }                                                              │
│                                                                      │
│      # 只处理比已处理更大序列号的事件                                 │
│      if event.sequence <= last_processed_sequence:                 │
│          return  # 跳过旧事件                                        │
│                                                                      │
│   2. 使用事件源 (Event Sourcing)                                    │
│      · 所有事件存储到 Kafka/Postgres                               │
│      · 按 sequence 排序处理                                         │
│                                                                      │
│   3. 接受无序 (最常见)                                               │
│      · 很多场景下无序不影响业务                                     │
│      · 支付场景必须有序                                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 6. 架构模式

### 6.1 简单接收 vs 队列处理

```
架构模式对比：

┌──────────────────────────────────────────────────────────────────────┐
│                        模式 1: 直接处理                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Server ──► POST /webhook ──► Handler ──► 业务逻辑                  │
│                                                                      │
│   优点：简单、低延迟                                                 │
│   缺点：无缓冲、可能丢失、重试困难                                    │
│   适用：小规模、低流量、有其他方式补偿                               │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        模式 2: 队列缓冲                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Server ──► POST /webhook ──► Queue ──► Worker ──► 业务逻辑         │
│                                   │                                  │
│                                   ▼                                  │
│                              [Redis/Kafka]                          │
│                                                                      │
│   优点：可靠、可扩展、可以限流                                       │
│   缺点：延迟增加、复杂度高                                           │
│   适用：生产环境、关键业务                                           │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                        模式 3: Fan-out                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Server ──► POST /webhook                                           │
│                 │                                                    │
│        ┌────────┴────────┐                                          │
│        ▼        ▼        ▼                                          │
│     Worker1  Worker2  Worker3                                       │
│        │        │        │                                          │
│        ▼        ▼        ▼                                          │
│     日志    通知    业务处理                                          │
│                                                                      │
│   优点：解耦、可独立扩展                                             │
│   缺点：需要消息路由                                                 │
│   适用：多消费者场景                                                 │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 6.2 消息过滤与路由

```
事件过滤策略：

┌──────────────────────────────────────────────────────────────────────┐
│                        事件路由                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. Header 级别过滤 (快速)                                          │
│      X-Webhook-Event: push                                          │
│                                                                      │
│      if event_type == "push":                                       │
│          handle_push()                                              │
│      elif event_type == "pull_request":                             │
│          handle_pr()                                               │
│                                                                      │
│   2. Payload 字段过滤 (精细)                                        │
│      if payload.get("action") == "opened" and \                    │
│         payload.get("pull_request", {}).get("base") == "main":    │
│          handle_main_pr_opened()                                   │
│                                                                      │
│   3. 多条件组合                                                     │
│      rules = [                                                      │
│          ("push", lambda p: p["ref"] == "refs/heads/main"),        │
│          ("pull_request", lambda p: p["action"] in ["opened",      │
│                           "closed"]),                               │
│      ]                                                              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 6.3 完整接收器架构

```python
# 完整 Webhook 接收器架构
from fastapi import FastAPI, Request, HTTPException, BackgroundTasks
from pydantic import BaseModel
from typing import Dict, List, Callable, Optional
import asyncio
import hashlib
import hmac
import time
import uuid
from enum import Enum
from dataclasses import dataclass, field
from collections import defaultdict

app = FastAPI()

# ---------------------------------------------------------------------------
# 配置
# ---------------------------------------------------------------------------

@dataclass
class WebhookConfig:
    """Webhook 配置"""
    secret: str
    max_retries: int = 5
    retry_delays: List[int] = field(default_factory=lambda: [30, 120, 600, 3600, 86400])
    timestamp_tolerance: int = 300

# ---------------------------------------------------------------------------
# 事件处理器
# ---------------------------------------------------------------------------

class EventRouter:
    """事件路由器"""

    def __init__(self):
        self.handlers: Dict[str, List[Callable]] = defaultdict(list)

    def on(self, event_type: str):
        """装饰器：注册事件处理器"""
        def decorator(func: Callable):
            self.handlers[event_type].append(func)
            return func
        return decorator

    async def dispatch(self, event_type: str, payload: dict):
        """分发事件到对应处理器"""
        handlers = self.handlers.get(event_type, [])
        results = []
        for handler in handlers:
            result = await handler(payload)
            results.append(result)
        return results

router = EventRouter()

# ---------------------------------------------------------------------------
# Webhook 验证
# ---------------------------------------------------------------------------

class WebhookVerifier:
    """Webhook 签名验证器"""

    def __init__(self, config: WebhookConfig):
        self.config = config

    def verify(self, body: bytes, headers: dict) -> bool:
        """验证请求签名"""
        signature = headers.get("x-webhook-signature", "")
        timestamp = headers.get("x-webhook-timestamp", "")

        # 时间戳检查
        if timestamp:
            ts = int(timestamp)
            if abs(time.time() - ts) > self.config.timestamp_tolerance:
                return False

        # 签名检查
        expected = f"sha256={hmac.new(
            self.config.secret.encode(),
            body,
            hashlib.sha256
        ).hexdigest()}"

        return hmac.compare_digest(expected, signature)

# ---------------------------------------------------------------------------
# 幂等存储
# ---------------------------------------------------------------------------

class InMemoryIdempotencyStore:
    """内存幂等存储 (生产环境用 Redis)"""

    def __init__(self, ttl: int = 86400 * 7):
        self.processed: Dict[str, tuple] = {}
        self.ttl = ttl

    def is_processed(self, event_id: str) -> bool:
        if event_id not in self.processed:
            return False
        timestamp, = self.processed[event_id]
        if time.time() - timestamp > self.ttl:
            del self.processed[event_id]
            return False
        return True

    def mark_processed(self, event_id: str):
        self.processed[event_id] = (time.time(),)

# ---------------------------------------------------------------------------
# 重试队列
# ---------------------------------------------------------------------------

class RetryQueue:
    """简单内存重试队列 (生产环境用 Redis/RabbitMQ)"""

    def __init__(self, retry_delays: List[int]):
        self.retry_delays = retry_delays
        self.queue: List[tuple] = []  # (retry_at, event_type, payload, attempt)

    async def push(self, event_type: str, payload: dict, attempt: int = 0):
        if attempt >= len(self.retry_delays):
            return  # 超过最大重试次数

        delay = self.retry_delays[attempt]
        retry_at = time.time() + delay
        self.queue.append((retry_at, event_type, payload, attempt + 1))
        self.queue.sort(key=lambda x: x[0])

    async def pop(self) -> Optional[tuple]:
        """获取到期的重试项"""
        if not self.queue:
            return None
        retry_at, event_type, payload, attempt = self.queue[0]
        if time.time() >= retry_at:
            self.queue.pop(0)
            return (event_type, payload, attempt)
        return None

# ---------------------------------------------------------------------------
# Webhook 应用
# ---------------------------------------------------------------------------

config = WebhookConfig(secret="whsec_test_secret_123")
verifier = WebhookVerifier(config)
idempotency = InMemoryIdempotencyStore()
retry_queue = RetryQueue(config.retry_delays)

@app.post("/webhook")
async def handle_webhook(
    request: Request,
    background_tasks: BackgroundTasks
):
    """Webhook 接收端点"""
    body = await request.body()
    headers = dict(request.headers)

    # 1. 签名验证
    if not verifier.verify(body, headers):
        raise HTTPException(status_code=401, detail="Invalid signature")

    # 2. 解析事件
    import json
    payload = json.loads(body)
    event_type = headers.get("x-webhook-event", "unknown")
    event_id = headers.get("x-webhook-id", str(uuid.uuid4()))

    # 3. 幂等检查
    if idempotency.is_processed(event_id):
        return {"status": "already_processed", "event_id": event_id}

    # 4. 异步处理
    background_tasks.add_task(process_event, event_type, payload, event_id)

    return {"status": "accepted", "event_id": event_id}

async def process_event(event_type: str, payload: dict, event_id: str):
    """异步处理事件"""
    try:
        await router.dispatch(event_type, payload)
        idempotency.mark_processed(event_id)
    except Exception as e:
        # 失败则加入重试队列
        await retry_queue.push(event_type, payload)
        raise

# ---------------------------------------------------------------------------
# 事件处理器注册
# ---------------------------------------------------------------------------

@router.on("push")
async def handle_push(payload: dict):
    print(f"Push to {payload.get('ref')} by {payload.get('pusher', {}).get('name')}")

@router.on("pull_request")
async def handle_pr(payload: dict):
    action = payload.get("action")
    pr = payload.get("pull_request", {})
    print(f"PR #{pr.get('number')} {action}: {pr.get('title')}")
```

---

## 7. 主流平台实现

### 7.1 GitHub Webhooks

```
GitHub Webhook 详解：

┌──────────────────────────────────────────────────────────────────────┐
│                        GitHub Webhook                               │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   注册方式：                                                         │
│   Repository Settings → Webhooks → Add webhook                     │
│                                                                      │
│   配置项：                                                           │
│   · Payload URL: https://your-server.com/webhook                   │
│   · Content type: application/json                                  │
│   · Secret: 建议设置，不设置则不验证                                  │
│   · Events: 选择性订阅                                               │
│                                                                      │
│   事件类型：                                                         │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  push              │  代码推送                              │     │
│   │  pull_request      │  PR 相关事件                          │     │
│   │  issues            │  Issue 事件                           │     │
│   │  issue_comment     │  Issue 评论                           │     │
│   │  create            │  分支/标签创建                        │     │
│   │  delete            │  分支/标签删除                        │     │
│   │  fork              │  仓库 fork                            │     │
│   │  watch             │  Star                                 │     │
│   │  release           │  Release 发布                         │     │
│   │  workflow_run      │  GitHub Actions                      │     │
│   │  * (wildcard)      │  接收所有事件                         │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   签名验证：                                                         │
│   · Header: X-Hub-Signature-256                                      │
│   · 格式: sha256=<hex>                                              │
│   · 签名内容: raw request body                                      │
│   · Secret: 手动设置的值                                            │
│                                                                      │
│   投递行为：                                                         │
│   · 无验证时不签名                                                   │
│   · 超时 30 秒                                                      │
│   · 5xx 错误无限重试                                                 │
│   · 4xx 错误不重试                                                   │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 7.2 Stripe Webhooks

```
Stripe Webhook 详解：

┌──────────────────────────────────────────────────────────────────────┐
│                        Stripe Webhook                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   注册方式：                                                         │
│   Stripe Dashboard → Developers → Webhooks                          │
│                                                                      │
│   签名验证特点：                                                     │
│   · Header: Stripe-Signature                                         │
│   · 格式: t=<timestamp>,v1=<signature>,v0=<legacy>                  │
│   · 带时间戳，防重放攻击                                             │
│   · 推荐用 stripe-node SDK 验证                                      │
│                                                                      │
│   事件类型：                                                         │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  payment_intent.succeeded    │  支付成功                  │     │
│   │  payment_intent.payment_failed│  支付失败                 │     │
│   │  charge.succeeded             │  扣款成功                 │     │
│   │  customer.subscription.created│  订阅创建                 │     │
│   │  invoice.payment_failed       │  扣款失败                 │     │
│   │  payout.paid                  │  提现成功                 │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   端点测试：                                                         │
│   · Stripe CLI: stripe listen --forward-to localhost:3000/webhook  │
│   · Test mode events                                                │
│                                                                      │
│   最佳实践：                                                         │
│   · 收到事件后先返回 200，再异步处理                                  │
│   · 使用事件 ID 幂等                                                 │
│   · 处理失败时返回 500 触发重试                                      │
│   · 订阅所有相关事件，不只处理成功的                                  │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

```python
# Stripe Webhook 验证 (使用 SDK)
from stripe import Webhook, error as stripe_error

@app.post("/webhook/stripe")
async def handle_stripe_webhook(request: Request):
    payload = await request.body()
    sig_header = request.headers.get("stripe-signature")
    endpoint_secret = "whsec_xxx"  # 从 Stripe Dashboard 获取

    try:
        event = Webhook.construct_event(
            payload, sig_header, endpoint_secret
        )
    except stripe_error.SignatureVerificationError:
        raise HTTPException(status_code=400, detail="Invalid signature")

    # 处理事件
    if event["type"] == "payment_intent.succeeded":
        payment_intent = event["data"]["object"]
        await handle_payment_success(payment_intent)
    elif event["type"] == "payment_intent.payment_failed":
        payment_intent = event["data"]["object"]
        await handle_payment_failure(payment_intent)

    return {"status": "received"}
```

### 7.3 Slack Webhooks

```
Slack Webhook 详解：

┌──────────────────────────────────────────────────────────────────────┐
│                        Slack Webhook                                 │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Slack 两种 Webhook：                                               │
│                                                                      │
│   1. Incoming Webhook (发送)                                        │
│      ┌──────────────────────────────────────────────────────────┐   │
│      │  用途：Slack → 外部服务 (单向推送)                        │   │
│      │  格式：POST 到 Webhook URL                               │   │
│      │  Payload: { "text": "Hello", "blocks": [...] }          │   │
│      └──────────────────────────────────────────────────────────┘   │
│                                                                      │
│   2. Slack Events API (接收)                                        │
│      ┌──────────────────────────────────────────────────────────┐   │
│      │  用途：外部服务 → Slack (双向订阅)                        │   │
│      │  方式：Webhook URL + Request URL                        │   │
│      │  验证：X-Slack-Signature header                          │   │
│      └──────────────────────────────────────────────────────────┘   │
│                                                                      │
│   Slack Events API 请求 URL配置：                                    │
│   · Request URL: 必须是公网 HTTPS                                   │
│   · Slack 会先验证 URL 有效性                                        │
│   · Challenge: Slack 发送 challenge，服务器返回 response            │
│                                                                      │
│   签名验证：                                                         │
│   · Header: X-Slack-Signature                                      │
│   · 格式: v0=<signature>                                            │
│   · 签名内容: v0:<timestamp>.<body>                                 │
│   · 时间戳容差: 5 分钟                                              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

```python
# Slack Events API 签名验证
import hmac
import hashlib
import time

def verify_slack_signature(body: str, timestamp: str,
                           signature: str, signing_secret: str) -> bool:
    """
    验证 Slack 请求签名

    Args:
        body: 原始请求 body
        timestamp: X-Slack-Request-Timestamp header
        signature: X-Slack-Signature header
        signing_secret: Slack App 的 Signing Secret
    """
    # 1. 时间戳检查 (防止重放)
    if abs(time.time() - int(timestamp)) > 60 * 5:
        return False

    # 2. 计算签名
    base = f"v0:{timestamp}:{body}"
    expected = 'v0=' + hmac.new(
        signing_secret.encode(),
        base.encode(),
        hashlib.sha256
    ).hexdigest()

    return hmac.compare_digest(expected, signature)
```

### 7.4 平台对比

```
平台 Webhook 功能对比：

┌──────────────────────────────────────────────────────────────────────┐
│                   平台 Webhook 功能对比                              │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   ┌────────────────────────────────────────────────────────────────┐ │
│   │  功能              │  GitHub  │  Stripe  │  Slack  │  自建   │ │
│   │  ──────────────────┼──────────┼──────────┼─────────┼─────────│ │
│   │  HMAC 签名         │  SHA256  │  SHA256  │  SHA256 │  ✓      │ │
│   │  时间戳签名        │  ✗       │  ✓       │  ✓      │  ✓     │ │
│   │  事件 ID          │  ✓       │  ✓       │  ✗      │  ✓     │ │
│   │  唯一投递 ID      │  ✓       │  ✓       │  ✗      │  ✓     │ │
│   │  重试机制         │  无限    │  72h无限 │  3次    │  可配   │ │
│   │  重试间隔         │  10s→2h  │  1m→24h  │  自动   │  可配   │ │
│   │  超时时间         │  30s     │  300s    │  即时   │  可配   │ │
│   │  TLS 要求         │  ✓       │  ✓       │  ✓      │  ✓     │ │
│   │  IP 白名单        │  ✗       │  ✗       │  ✗      │  ✓     │ │
│   │  测试事件发送     │  ✓       │  ✓       │  ✓      │  ✓     │ │
│   │  事件过滤         │  事件类型 │  事件类型│  URL选择 │  ✓     │ │
│   │  批量事件         │  ✗       │  ✓       │  ✗      │  ✓     │ │
│   └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 8. 调试与测试

### 8.1 本地调试工具

```
本地调试方案：

┌──────────────────────────────────────────────────────────────────────┐
│                        调试工具                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. ngrok (公网映射)                                               │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  ngrok http 3000                                           │     │
│   │  → Forwarding: https://abc123.ngrok.io                    │     │
│   │  → Webhook URL: https://abc123.ngrok.io/webhook           │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   2. cloudflared (Cloudflare Tunnel)                                │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  cloudflared tunnel --url http://localhost:3000           │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   3. localtunnel                                                    │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  npx localtunnel --port 3000                               │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   4. Stripe CLI (Stripe 专用)                                       │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  stripe listen --forward-to localhost:3000/webhook        │     │
│   │  stripe trigger payment_intent.succeeded                  │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   5. GitHub CLI                                                     │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  gh webhook forward --repo owner/repo                      │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 8.2 请求日志与抓包

```
抓包与调试：

┌──────────────────────────────────────────────────────────────────────┐
│                        请求调试                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   1. Webhook 请求日志                                               │
│   @app.post("/webhook")                                            │
│   async def handle_webhook(request: Request):                      │
│       # 记录原始请求                                                │
│       body = await request.body()                                   │
│       headers = dict(request.headers)                               │
│       logger.info({                                                 │
│           "event": headers.get("x-webhook-event"),                  │
│           "delivery": headers.get("x-github-delivery"),            │
│           "signature": headers.get("x-hub-signature-256"),         │
│           "payload_size": len(body),                                │
│           "timestamp": time.time()                                  │
│       })                                                             │
│                                                                      │
│   2. 使用mitmproxy 抓包                                             │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  mitmproxy -p 8080 --ssl-insecure                         │     │
│   │  → 浏览器配置 HTTP_PROXY=http://localhost:8080           │     │
│   │  → 查看所有 HTTP 请求                                      │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
│   3. curl 手动测试                                                  │
│   ┌────────────────────────────────────────────────────────────┐     │
│   │  curl -X POST https://your-server/webhook \              │     │
│   │    -H "Content-Type: application/json" \                  │     │
│   │    -H "X-Webhook-Signature: sha256=xxx" \               │     │
│   │    -d '{"event": "test", "data": "hello"}'              │     │
│   └────────────────────────────────────────────────────────────┘     │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### 8.3 测试框架

```python
# Webhook 测试框架
import pytest
from unittest.mock import Mock, patch
import json
import hashlib
import hmac
import time

class WebhookTestClient:
    """Webhook 测试客户端"""

    def __init__(self, app, secret: str):
        self.app = app
        self.secret = secret.encode()

    def _sign(self, body: bytes) -> str:
        """生成测试签名"""
        return "sha256=" + hmac.new(
            self.secret, body, hashlib.sha256
        ).hexdigest()

    async def post_webhook(self, event_type: str, payload: dict,
                           delivery_id: str = None):
        """发送测试 Webhook 请求"""
        from starlette.testclient import TestClient
        body = json.dumps(payload).encode()
        headers = {
            "content-type": "application/json",
            "x-webhook-event": event_type,
            "x-webhook-id": delivery_id or "test-delivery-123",
            "x-webhook-signature": self._sign(body),
            "x-webhook-timestamp": str(int(time.time())),
        }
        return TestClient(self.app).post(
            "/webhook", content=body, headers=headers
        )

# ---------------------------------------------------------------------------
# 测试用例
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_valid_webhook(测试客户端):
    """测试有效 Webhook 请求"""
    response = await 测试客户端.post_webhook(
        event_type="push",
        payload={
            "ref": "refs/heads/main",
            "repository": {"full_name": "test/repo"}
        }
    )
    assert response.status_code == 200
    assert response.json()["status"] == "accepted"

@pytest.mark.asyncio
async def test_invalid_signature(测试客户端):
    """测试无效签名"""
    from starlette.testclient import TestClient
    body = json.dumps({"test": "data"}).encode()
    response = TestClient(测试客户端.app).post(
        "/webhook",
        content=body,
        headers={
            "x-webhook-signature": "sha256=invalid",
            "x-webhook-event": "test",
        }
    )
    assert response.status_code == 401

@pytest.mark.asyncio
async def test_idempotency(测试客户端):
    """测试幂等性：重复请求只处理一次"""
    delivery_id = "test-idempotency-123"
    payload = {"event": "test", "data": "hello"}

    # 第一次请求
    r1 = await 测试客户端.post_webhook("test", payload, delivery_id)
    assert r1.status_code == 200

    # 第二次相同 delivery_id
    r2 = await 测试客户端.post_webhook("test", payload, delivery_id)
    assert r2.status_code == 200
    assert r2.json()["status"] == "already_processed"
```

---

## 9. 安全最佳实践

```
安全检查清单：

┌──────────────────────────────────────────────────────────────────────┐
│                        安全清单                                      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   □ 强制 HTTPS                                                       │
│     · Webhook URL 必须是 https://                                  │
│     · 验证 SSL 证书                                                 │
│     · 禁用 HTTP 回退                                                 │
│                                                                      │
│   □ 签名验证                                                         │
│     · 验证 HMAC-SHA256 签名                                        │
│     · 包含时间戳防止重放攻击                                         │
│     · 使用 timing-safe 比较                                         │
│                                                                      │
│   □ 输入验证                                                         │
│     · 验证 Content-Type                                            │
│     · 限制 body 大小 (如 1MB)                                      │
│     · 验证 JSON 格式                                                │
│     · 白名单验证事件类型                                            │
│                                                                      │
│   □ 限流保护                                                         │
│     · 单 IP 限流                                                    │
│     · 全局限流                                                      │
│     · 429 时返回 Retry-After header                                │
│                                                                      │
│   □ 日志与监控                                                       │
│     · 记录所有 Webhook 请求                                          │
│     · 监控失败率                                                     │
│     · 告警异常模式                                                   │
│                                                                      │
│   □ 网络隔离                                                         │
│     · Webhook 端点不暴露其他 API                                    │
│     · 使用独立域名                                                   │
│     · 考虑 IP 白名单 (GitHub/AWS IP 范围)                           │
│                                                                      │
│   □ 错误处理                                                         │
│     · 不要在错误响应中返回敏感信息                                   │
│     · 失败时返回 500 触发重试 (非 400)                               │
│     · 记录详细错误日志 (不返回给客户端)                             │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 10. Hermes Webhook Subscriptions 实战

```
Hermes Webhook Subscriptions：

┌──────────────────────────────────────────────────────────────────────┐
│                        Hermes Webhook                                │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│   Hermes 内置的 Webhook 订阅管理平台                                  │
│   用途：外部服务触发 Agent 任务                                      │
│                                                                      │
│   工作流程：                                                         │
│   1. 用户注册 Webhook 订阅 (指定 prompt 模板和事件)                  │
│   2. 外部服务 POST 事件到 Webhook URL                              │
│   3. Hermes 格式化 prompt，触发 Agent 执行                          │
│   4. Agent 结果推送到指定渠道 (Telegram/Discord/etc.)              │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

```bash
# Hermes Webhook 使用示例

# 启用 Webhook 平台
hermes gateway setup
# 或手动配置 ~/.hermes/config.yaml:
# platforms:
#   webhook:
#     enabled: true
#     port: 8644
#     secret: "your-global-secret"

# 创建订阅：GitHub Issue 自动分类
hermes webhook subscribe github-issue-triage \
  --events "issues" \
  --prompt "New GitHub issue #{issue.number}: {issue.title}
Action: {action}
Author: {issue.user.login}
Body: {issue.body}
Please triage and label this issue." \
  --skills "github-issues" \
  --deliver telegram \
  --deliver-chat-id "-100123456789"

# 返回:
# Webhook URL: https://your-gateway:8644/webhook/github-issue-triage
# Secret: whsec_abc123...
#
# 配置到 GitHub: Settings → Webhooks → Add webhook
# Payload URL: https://your-gateway:8644/webhook/github-issue-triage
# Secret: whsec_abc123...
# Events: Issues

# 查看订阅列表
hermes webhook list

# 测试订阅
hermes webhook test github-issue-triage \
  --payload '{"issue": {"number": 123, "title": "Bug: login fails", "body": "Steps to reproduce..."}}'

# 删除订阅
hermes webhook remove github-issue-triage
```

---

## 11. 总结

```
核心要点：

1. Webhook = 服务端主动推送的 HTTP POST 回调
2. 签名验证 = HMAC-SHA256 (GitHub) 或 带时间戳版本 (Stripe/Slack)
3. 幂等性 = 使用唯一事件 ID 防止重复处理
4. 重试机制 = 指数退避 + 最大重试次数
5. 架构选型 = 简单直接处理 vs 队列缓冲
6. 安全 = HTTPS + 签名验证 + 限流 + 输入验证

平台差异：
  · GitHub: 简单 HMAC，无时间戳
  · Stripe: 带时间戳，防重放
  · Slack: Slack 专用签名格式
  · 自建: 推荐带时间戳的 HMAC-SHA256

生产环境必备：
  · 幂等存储
  · 重试队列
  · 监控告警
  · 限流保护
```

---

## 延伸阅读

### 文档

- GitHub Webhooks: https://docs.github.com/en/webhooks
- Stripe Webhooks: https://stripe.com/docs/webhooks
- Slack Events API: https://api.slack.com/apis/connections/events-api
- MCP Webhook (Anthropic): https://modelcontextprotocol.io

### 工具

- ngrok: https://ngrok.com
- Stripe CLI: https://stripe.com/docs/stripe-cli
- mitmproxy: https://mitmproxy.org
