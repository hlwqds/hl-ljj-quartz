---
title: "VPN 技术深度探索 (二十七)：V2Ray 技术体系"
date: 2026-04-13
tags: [vpn, series, v2ray, vmess, vless, websocket, trojan, proxy]
description: "V2Ray 全面解析——VMess/VLESS 协议、WebSocket/TLS/CDN 传输、Xray 分支、性能对比、配置模板与最佳实践"
---

> [!info] VPN 技术深度探索系列
> 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-vpn-deep-dive-ch26-shadowsocksr|ShadowsocksR]]
> 2. **第二十七章：V2Ray 技术体系**
> 3. [[2026-04-13-vpn-deep-dive-ch28-trojan|第二十八章：Trojan 协议]]
> 4. [[2026-04-13-vpn-deep-dive-ch29-xray|第二十九章：Xray 核心]]

---

## 1. 概述：V2Ray 项目背景

**V2Ray** 是 ronychan（不良叫兽）于 2014 年开发的翻墙框架，定位为**模块化的代理平台**，不只是简单的 SOCKS5 代理。V2Ray 的设计理念是**一切皆可配置**，通过组合不同的协议、传输方式和伪装方案来对抗 GFW。

```
V2Ray 定位：

┌─────────────────────────────────────────────────────────────────┐
│                      V2Ray vs Shadowsocks                       │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Shadowsocks（轻量级代理）：                                      │
│  ├─ SOCKS5 代理                                                  │
│  ├─ 单协议设计                                                  │
│  ├─ 轻量级                                                      │
│  └─ 易用但灵活性差                                               │
│                                                                 │
│  V2Ray（模块化代理平台）：                                        │
│  ├─ 多协议支持（VMess、VLESS、Trojan）                          │
│  ├─ 多传输方式（TCP、WebSocket、mKCP、QUIC）                    │
│  ├─ 多伪装方案（TLS、HTTP/2、gRPC）                             │
│  ├─ 路由功能（域名/IP/规则分流）                                  │
│  └─ 高度可配置                                                  │
│                                                                 │
│  V2Ray 核心特性：                                                │
│  ├─ VMess 协议（自研加密协议）                                   │
│  ├─ VLESS 协议（更轻量的纯 TLS 协议）                            │
│  ├─ WebSocket 传输（可使用 CDN）                                 │
│  ├─ 完善的重连和错误处理                                         │
│  └─ 原生 SOCKS/HTTP/VMess 协议支持                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. VMess 协议详解

### 2.1 VMess 协议原理

**VMess（VMess protocol）** 是 V2Ray 自研的加密传输协议，设计目标是在提供加密和安全性的同时，减少协议特征：

```
VMess 协议特点：

┌─────────────────────────────────────────────────────────────────┐
│                      VMess 协议架构                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  基础设计：                                                      │
│  ├─ 基于 HMAC + AES 的加密协议                                  │
│  ├─ 用户 ID（UUID）用于身份认证                                  │
│  ├─ 加密的元数据（metadata）                                     │
│  ├─ 动态端口支持                                                │
│  └─ 时间同步认证                                                │
│                                                                 │
│  数据包结构：                                                    │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ VMess 数据包                                              │   │
│  ├──────────────────────────────────────────────────────────┤   │
│  │ [16 bytes]  认证信息 (HMAC)                               │   │
│  │ [4 bytes]   时间戳 (timestamp)                            │   │
│  │ [16 bytes]  认证数据 (IV/Nonce)                           │   │
│  │ [N bytes]   加密数据 (encrypted payload)                  │   │
│  │ [16 bytes]  消息认证 (MAC)                                 │   │
│  └──────────────────────────────────────────────────────────┘   │
│                                                                 │
│  字段说明：                                                      │
│  ├─ HMAC：使用用户密钥计算，认证信息来源                         │
│  ├─ 时间戳：防止重放攻击（允许 ±120 秒）                         │
│  ├─ IV/Nonce：加密初始化向量                                    │
│  └─ MAC：消息完整性认证                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 VMess 认证机制

VMess 使用 UUID 作为用户标识符：

```
VMess 认证流程：

┌─────────────────────────────────────────────────────────────────┐
│                    VMess 认证机制                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 用户配置                                                    │
│     ├─ User ID (UUID)：用户唯一标识                              │
│     ├─ AlterId：额外 ID 数量（用于密钥派生）                      │
│     └─ 密钥：通过 UUID + AlterId 派生                            │
│                                                                 │
│  2. 连接建立                                                    │
│     Client ──── Client Hello ──────────────────────▶ Server     │
│              │                                               │
│              │ UUID + 时间戳 + 随机数                          │
│              │ HMAC-SHA256 认证                               │
│              │                                               │
│  Server 验证：                                                  │
│     ├─ 检查 UUID 是否存在                                       │
│     ├─ 检查时间戳是否在允许范围内                                │
│     ├─ 验证 HMAC                                               │
│     └─ 检查是否重放（使用短窗口缓存）                            │
│                                                                 │
│  3. 密钥交换                                                    │
│     ├─ 使用 AES-128-CFB 或 AES-256-GCM                         │
│     └─ 每次连接使用新的 IV                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 VMess 版本

VMess 有多个版本：

```
VMess 版本：

VMess MD5（原始版，已废弃）：
├─ 密钥派生：MD5(UUID + AlterId)
├─ 加密：AES-128-CFB
├─ 认证：HMAC-MD5
└─ 安全性：低（MD5 弱点）

VMess AEAD（推荐）：
├─ 密钥派生：AES 密钥派生函数
├─ 加密：AES-128-GCM / AES-256-GCM
├─ 认证：Poly1305
├─ 防重放：启用
└─ 安全性：中-高

VMess AES-GCM（现代版）：
├─ 加密：AES-256-GCM
├─ 认证：内置
└─ 推荐使用
```

---

## 3. VLESS 协议

### 3.1 VLESS 设计理念

**VLESS** 是 V2Ray 后续开发的轻量级协议，设计目标：**去掉 VMess 的加密层，直接使用 TLS**：

```
VLESS vs VMess：

┌─────────────────────────────────────────────────────────────────┐
│                        协议对比                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  VMess：                                                         │
│  ├─ 自定义加密层                                                 │
│  ├─ HMAC 认证                                                   │
│  ├─ 时间同步要求                                                │
│  └─ 协议特征明显                                                │
│                                                                 │
│  VLESS：                                                         │
│  ├─ 纯 TLS 传输（直接使用 TLS）                                  │
│  ├─ 无自定义加密                                                │
│  ├─ 无时间同步要求                                              │
│  └─ 更像正常 HTTPS 流量                                         │
│                                                                 │
│  VLESS 优势：                                                    │
│  ├─ 更好的 TLS 伪装                                             │
│  ├─ 更低的 CPU 开销（TLS offload）                              │
│  ├─ 更难被 DPI 检测                                             │
│  └─ 可以使用真实 TLS 证书                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 VLESS 协议格式

```
VLESS 数据包：

┌─────────────────────────────────────────────────────────────────┐
│                    VLESS 协议格式                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  请求头（明文）：                                                │
│  ├─ [16 bytes]  UUID（用户标识）                                │
│  ├─ [1 byte]   版本号（0x01）                                   │
│  ├─ [1 byte]   附加信息长度                                      │
│  ├─ [N bytes]  附加信息                                          │
│  │   ├─ 0x00: 无附加                                            │
│  │   └─ 0x01: TLV 格式                                          │
│  └─ [2 bytes]  端口（目标）                                     │
│                                                                 │
│  传输层：                                                        │
│  └─ 直接使用 TLS 加密传输                                        │
│                                                                 │
│  特点：                                                          │
│  ├─ 请求头是明文的（UUID 用于路由）                              │
│  ├─ 数据部分完全加密                                            │
│  └─ TLS 层面无法区分 VLESS 和正常 HTTPS                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 VLESS + XTLS

XTLS 是 VLESS 的增强版，提供了更完整的 TLS 伪装：

```
VLESS + XTLS 架构：

┌─────────────────────────────────────────────────────────────────┐
│                    XTLS 工作原理                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  传统 VLESS over TLS：                                           │
│                                                                 │
│  Client ──▶ VLESS Header ──▶ TLS 加密 ──▶ Server                 │
│            │                                                    │
│            └─ GFW 可以看到 VLESS Header（虽然是加密的）           │
│                                                                 │
│  VLESS + XTLS（XTLS 模式）：                                     │
│                                                                 │
│  Client ──▶ TLS 加密（VLESS Header 内） ──▶ Server               │
│            │                                                    │
│            └─ GFW 只能看到 TLS，无法解析内容                      │
│                                                                 │
│  XTLS 核心改进：                                                 │
│  ├─ VLESS Header 直接放在 TLS 内部加密                           │
│  ├─ 使用 TLS 1.3 的 EncryptedExtensions                        │
│  └─ 更难被检测                                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 传输方式

### 4.1 TCP 传输

基础的 TCP 传输方式：

```
TCP 传输：

Client ───────────────────────────▶ Server
         [原始 VMess/VLESS 数据]

特点：
├─ 简单直接
├─ 易被 TCP 干扰
└─ 可配合 TLS 使用
```

### 4.2 WebSocket 传输

WebSocket 传输支持 CDN 和 HTTP/2：

```
WebSocket 传输：

┌─────────────────────────────────────────────────────────────────┐
│                    WebSocket 传输架构                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Client ──▶ TLS ──▶ CDN ──▶ WebSocket ──▶ Server                │
│               │                         │                        │
│               │   HTTPS/443 端口        │                        │
│               │                         │                        │
│  HTTP Upgrade:                                           │
│  GET /ws HTTP/1.1                                        │
│  Host: example.com                                        │
│  Upgrade: websocket                                       │
│  Connection: Upgrade                                      │
│  Sec-WebSocket-Key: ...                                   │
│                                                                 │
│  特点：                                                         │
│  ├─ 使用标准 WebSocket 协议                                     │
│  ├─ 可使用 CDN 隐藏真实 IP                                      │
│  ├─ 可使用域前置                                                │
│  └─ 支持 HTTP/2 multiplexing                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 mKCP 传输

mKCP 是 KCP 协议的 V2Ray 实现，用于 UDP 伪装：

```
mKCP 传输：

┌─────────────────────────────────────────────────────────────────┐
│                      mKCP 特性                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  底层：UDP                                                       │
│                                                                 │
│  特性：                                                          │
│  ├─ 可伪装成 UDP 流量（视频通话等）                               │
│  ├─ 前向纠错（FEC）                                              │
│  ├─ 快速重传                                                    │
│  └─ 带宽估计                                                    │
│                                                                 │
│  配置示例：                                                      │
│  {                                                              │
│    "protocol": "vmess",                                        │
│    "streamSettings": {                                         │
│      "network": "mkcp",                                        │
│      "mkcpSettings": {                                         │
│        "mtu": 1350,                                            │
│        "tti": 50,                                              │
│        "uplinkCapacity": 12,                                    │
│        "downlinkCapacity": 100,                                │
│        "congestion": true,                                     │
│        "readBuffer": 2,                                         │
│        "writeBuffer": 2                                        │
│      }                                                         │
│    }                                                           │
│  }                                                              │
│                                                                 │
│  适用场景：                                                      │
│  ├─ 高延迟高丢包网络                                             │
│  └─ 需要 UDP 伪装时                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.4 QUIC 传输

```
QUIC 传输：

├─ 基于 UDP
├─ TLS 1.3 原生支持
├─ 0-RTT 快速恢复
├─ 多路复用
└─ 连接迁移（Connection Migration）

配置：
{
  "network": "quic",
  "quicSettings": {
    "security": "aes-128-gcm",
    "key": "your-key"
  }
}
```

---

## 5. TLS 配置与 CDN

### 5.1 TLS 设置

V2Ray 支持完整的 TLS 配置：

```
TLS 配置示例：

{
  "outbound": {
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "example.com",
        "port": 443,
        "users": [{
          "id": "uuid-here",
          "encryption": "none"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "tlsSettings": {
        "serverName": "example.com",
        "alpn": ["h2", "http/1.1"],
        "certificates": [{
          "certificateFile": "/path/to/cert.pem",
          "keyFile": "/path/to/key.pem"
        }],
        "rejectUnknownSni": true
      }
    }
  }
}
```

### 5.2 CDN 配合

V2Ray 支持通过 CDN 中转：

```
CDN 配合架构：

无 CDN：
Client ──────────────────────────▶ Server
         真实 IP 可被追踪

有 CDN：
Client ───▶ CDN ───▶ Server
            │
            └── 真实 IP 被 CDN 隐藏

配置：
{
  "outbound": {
    "protocol": "vless",
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/your-path",
        "headers": {
          "Host": "cdn-domain.com"
        }
      },
      "tlsSettings": {
        "serverName": "cdn-domain.com"
      }
    }
  }
}

限制：
├─ CDN 只支持 HTTP/2 WebSocket
├─ TLS 必须启用
└─ 速度受 CDN 限制
```

---

## 6. 路由系统

### 6.1 路由规则

V2Ray 内置强大的路由功能：

```
路由配置：

{
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:cn"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:cn"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "udp,tcp",
        "outboundTag": "proxy"
      }
    ]
  }
}

规则类型：
├─ domain：域名匹配
│   ├─ 精确匹配：example.com
│   ├─ 域名后缀：example.com
│   └─ 关键字：regexp:.*
├─ ip：IP 匹配（需 geoip 数据库）
└─ network：协议类型
```

### 6.2 分流策略

```
分流策略：

国内流量（direct）：
├─ 目标 IP 属于中国
├─ 目标域名属于中国
└─ 使用直连

国外流量（proxy）：
├─ 其他所有流量
└─ 通过代理服务器

域名预判：
├─ geosite:cn — 中国域名
├─ geosite:category-!@filter — 非过滤域名
└─ geosite:telegram — Telegram 相关

IP 预判：
├─ geoip:private — 私有 IP
├─ geoip:cn — 中国 IP
└─ geoip:telegram — Telegram IP
```

---

## 7. 配置模板与最佳实践

### 7.1 VLESS + WebSocket + TLS 配置

```
完整服务端配置（VLESS + WebSocket + TLS）：

{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "uuid-here",
        "level": 0
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/vless"
      },
      "tlsSettings": {
        "serverName": "your-domain.com",
        "certificates": [{
          "certificateFile": "/etc/ssl/cert.pem",
          "keyFile": "/etc/ssl/key.pem"
        }]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "tag": "direct"
  }]
}

客户端配置（对应）：

{
  "inbounds": [{
    "port": 1080,
    "protocol": "socks",
    "settings": {}
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "your-domain.com",
        "port": 443,
        "users": [{
          "id": "uuid-here"
        }]
      }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/vless"
      }
    }
  }]
}
```

### 7.2 VMess + WebSocket + TLS + CDN

```
{
  "inbounds": [{
    "port": 443,
    "listen": "0.0.0.0",
    "protocol": "vmess",
    "settings": {
      "clients": [{
        "id": "uuid-here",
        "alterId": 64
      }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/vmess"
      },
      "tlsSettings": {
        "serverName": "cdn-domain.com",
        "alpn": ["h2", "http/1.1"]
      }
    }
  }]
}
```

---

## 8. V2Ray vs Xray vs 旧版

```
项目分支关系：

┌─────────────────────────────────────────────────────────────────┐
│                      V2Ray 项目家族                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  V2Ray（原始）：                                                 │
│  ├─ 作者：不良叫兽                                              │
│  ├─ 最后版本：5.x（停止维护）                                    │
│  └─ 协议：VMess、VLESS、Trojan、Shadowsocks                     │
│                                                                 │
│  Xray（V2Ray 分支）：                                           │
│  ├─ 作者：RPRX（XTLS 作者）                                     │
│  ├─ 维护活跃                                                    │
│  ├─ 支持所有 V2Ray 协议                                          │
│  ├─ 独家：VLESS+XTLS、Reality                                   │
│  └─ 性能优化                                                    │
│                                                                 │
│  如何选择：                                                      │
│  ├─ 需要 XTLS/Reality ──▶ Xray                                  │
│  ├─ 需要最新特性 ──▶ Xray                                       │
│  ├─ 简单使用 VMess ──▶ 两者皆可                                  │
│  └─ 生产环境推荐 Xray                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 9. 总结

```
V2Ray 核心要点：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  协议体系：                                                      │
│  ├─ VMess：自研加密协议（已逐步淘汰）                            │
│  ├─ VLESS：纯 TLS 协议（推荐）                                   │
│  └─ Trojan：TLS 伪装协议（V2Ray 也支持）                         │
│                                                                 │
│  传输方式：                                                      │
│  ├─ TCP：基础传输                                               │
│  ├─ WebSocket：CDN 友好                                         │
│  ├─ mKCP：UDP 伪装                                              │
│  └─ QUIC：现代 UDP                                              │
│                                                                 │
│  伪装方案：                                                      │
│  ├─ TLS：标准 HTTPS                                             │
│  ├─ HTTP/2：多路复用                                            │
│  └─ gRPC：Google RPC                                            │
│                                                                 │
│  路由能力：                                                      │
│  ├─ 域名/IP 分流                                                │
│  ├─ 规则订阅                                                    │
│  └─ 负载均衡                                                    │
│                                                                 │
│  当前建议：                                                      │
│  ├─ 推荐使用 Xray 替代 V2Ray                                     │
│  ├─ 协议优先 VLESS + TLS                                         │
│  └─ 配合 CDN 使用更安全                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

V2Ray 是翻墙技术从单一协议向模块化平台演进的重要里程碑。其设计理念影响了整个行业，VLESS/XTLS 协议更是成为当前最安全的翻墙方案之一。

---

## 参考资料

1. V2Ray. "Official Website." v2fly.org
2. VLESS Protocol. "Specification."
3. Xray. "Xray Core." github.com/XTLS
4. RPRX. "XTLS Vision." Official Documentation.
