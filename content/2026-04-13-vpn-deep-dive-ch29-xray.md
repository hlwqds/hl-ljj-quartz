---
title: "VPN 技术深度探索 (二十九)：Xray 核心"
date: 2026-04-13
tags: [vpn, series, xray, vless, xtls, reality, proxy, censorship]
description: "Xray 核心深度解析——VLESS+XTLS、Trojan-Go 协议融合、Reality 协议、vision 网络、mux.cool 多路复用、性能优化与最佳配置"
---

> [!info] VPN 技术深度探索系列 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-13-vpn-deep-dive-ch28-trojan|Trojan 协议]]
> 2. **第二十九章：Xray 核心**
> 3. [[2026-04-13-vpn-deep-dive-ch30-clash|第三十章：Clash 生态]]
> 4. [[2026-04-13-vpn-deep-dive-ch31-tls-cdn|第三十一章：TLS 伪装与 CDN]]

---

## 1. 概述：Xray 项目定位

**Xray** 是 RPRX（XTLS 协议作者）于 2021 年从 V2Ray 分叉出来的高端代理平台。Xray 的核心定位是**高性能翻墙协议实现**，独家支持 VLESS+XTLS 和 Reality 协议，是目前最先进的翻墙框架之一。

```
Xray vs V2Ray：

┌─────────────────────────────────────────────────────────────────┐
│                      Xray vs V2Ray                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  共同点：                                                        │
│  ├─ 协议兼容（VMess、VLESS、Trojan、Shadowsocks）                │
│  ├─ 传输方式（TCP、WebSocket、gRPC、mKCP）                       │
│  └─ 路由系统                                                    │
│                                                                 │
│  Xray 独有特性：                                                 │
│  ├─ VLESS+XTLS（完整 TLS 伪装）                                 │
│  ├─ Reality 协议（去除 SNI 指纹）                               │
│  ├─ Vision 网络（更好的 TLS 伪装）                               │
│  ├─ uTLS 库（模拟真实浏览器 TLS 指纹）                           │
│  ├─ 更活跃的维护                                                │
│  └─ 性能优化                                                    │
│                                                                 │
│  Xray 移除的特性：                                               │
│  ├─ V2Ray 5.x 的部分实验性功能                                  │
│  └─ 一些过时的协议                                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. VLESS+XTLS 协议

### 2.1 XTLS 设计目标

**XTLS** 是 RPRX 设计的完整 TLS 伪装协议，设计目标是**解决 VLESS over TLS 中的 SNI 泄露问题**：

```
SNI 泄露问题：

传统 TLS 1.2：
┌─────────────────────────────────────────────────────────────────┐
│ TLS ClientHello（明文 SNI）：                                    │
│                                                                 │
│ 00 00 00 10 01 00 00 06 05 01 02 ...                         │
│ 00 0e 00 0b 00 00 09 6e 67 69 6e ...  │  SNI: z-lib.org     │
│                                                                 │
│ 问题：GFW 可以看到明文的 SNI，识别目标域名                        │
└─────────────────────────────────────────────────────────────────┘

TLS 1.3 改进：
├─ TLS 1.3 中 SNI 被加密
├─ 但仍有部分信息泄露
└─ ECH（Encrypted Client Hello）是最终解决方案

XTLS 的解决方案：
└─ 直接在 TLS 内部传输，不使用 SNI
```

### 2.2 XTLS 工作原理

```
XTLS 架构：

┌─────────────────────────────────────────────────────────────────┐
│                    XTLS vs 普通 TLS                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  普通 VLESS over TLS：                                           │
│                                                                 │
│  Client ──▶ TLS ClientHello (SNI: example.com) ──▶ Server      │
│              │                                                 │
│              └── GFW 可以看到 SNI = example.com                 │
│                                                                 │
│  XTLS（无 SNI 模式）：                                           │
│                                                                 │
│  Client ──▶ TLS ClientHello (SNI: mask.com) ──▶ Server         │
│              │                                                 │
│              │ XTLS 使用 mask.com 作为外层 SNI                  │
│              │ 实际目标通过 XTLS 协议内部指定                    │
│              │                                                 │
│  Client ──▶ [VLESS Header + Target Domain] ──▶ Server         │
│              │                                                 │
│              │ 完全加密，GFW 无法看到真实目标                      │
│              │                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 XTLS 的 Vision 分支

XTLS 包含多个分支版本：

```
XTLS 版本演进：

┌─────────────────────────────────────────────────────────────────┐
│                      XTLS 版本                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  XTLS original（原始版）：                                        │
│  ├─ 首个完整 TLS 伪装实现                                        │
│  ├─ 使用 TLS 握手后的连接传输 VLESS                             │
│  └─ 已被 Vision 替代                                            │
│                                                                 │
│  XTLS vision（推荐）：                                           │
│  ├─ 更轻量的实现                                                │
│  ├─ 更好的兼容性                                                │
│  ├─ 修复了一些安全问题                                          │
│  └─ 当前推荐版本                                                │
│                                                                 │
│  XTLS vision+（增强版）：                                        │
│  ├─ vision 的增强版                                             │
│  ├─ 更好的性能                                                  │
│  └─ 更好的抗检测能力                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Reality 协议

### 3.1 Reality 设计理念

**Reality** 是 Xray 独有的协议，设计目标是**完全去除 TLS 指纹特征**：

```
Reality 核心思想：

┌─────────────────────────────────────────────────────────────────┐
│                      Reality vs XTLS                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  XTLS：                                                         │
│  ├─ 仍然使用真实 TLS 握手                                       │
│  ├─ SNI 被伪装，但证书指纹可被分析                               │
│  └─ GFW 可能通过证书指纹关联目标                                 │
│                                                                 │
│  Reality：                                                       │
│  ├─ 直接模拟目标网站的 TLS 指纹                                  │
│  ├─ 使用目标网站的真实证书（作为伪装的模板）                      │
│  ├─ 去除所有可识别的协议特征                                     │
│  └─ 流量与访问目标网站完全一致                                   │
│                                                                 │
│  比喻：                                                          │
│  ├─ XTLS：穿得像有钱人                                          │
│  └─ Reality：就是有钱人本人                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Reality 工作原理

```
Reality 工作流程：

┌─────────────────────────────────────────────────────────────────┐
│                    Reality 连接流程                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 客户端配置（伪装目标）                                        │
│     ├─ target: 目标网站（如 netflix.com）                        │
│     └─ SNI: 使用目标网站的 SNI                                   │
│                                                                 │
│  2. TLS 握手（模拟目标网站）                                     │
│                                                                 │
│  Client ──▶ TLS ClientHello ──▶ Server                          │
│            │                                                   │
│            │ SNI: netflix.com（目标网站的 SNI）                   │
│            │ 证书: 伪装用的证书                                   │
│            │ 指纹: 模拟 Chrome/Firefox                          │
│            │                                                   │
│  Server ◀── TLS Response ──────────────────────────────────────│
│                                                                 │
│  3. Xray 处理（内部路由）                                        │
│                                                                 │
│  Server:                                                        │
│  ├─ 收到 TLS 握手，分析 SNI                                     │
│  ├─ 发现 SNI = netflix.com                                     │
│  ├─ 判断这是 Reality 流量（通过 key 验证）                       │
│  ├─ 解密 VLESS Header，获取真实目标                              │
│  └─ 转发到真实目标（或直接代理）                                 │
│                                                                 │
│  4. 流量转发                                                    │
│                                                                 │
│  如果目标是代理服务器 ──▶ 正常代理流程                           │
│  Reality 的特别之处：                                           │
│  ├─ GFW 看到的是访问 netflix.com 的 TLS 流量                    │
│  └─ 实际上是在翻墙                                             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.3 Reality 配置

```
Reality 服务端配置：

{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "uuid-here",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.microsoft.com:443",
        "xver": 0,
        "serverNames": [
          "www.microsoft.com",
          "www.amazon.com",
          "www.apple.com"
        ],
        "privateKey": "your-private-key",
        "shortIds": ["", "0123456789abcdef"]
      }
    }
  }]
}

字段说明：
├─ dest: 伪装目标（GFW 看到你访问这个网站）
├─ serverNames: 允许的 SNI 列表
├─ privateKey: Reality 私钥
└─ shortIds: 客户端标识（可选）
```

---

## 4. Vision 网络

### 4.1 Vision 特性

**Vision** 是 Xray 的新传输模式，提供了更好的 TLS 伪装：

```
Vision 特性：

┌─────────────────────────────────────────────────────────────────┐
│                      Vision vs 普通模式                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  普通 TLS 模式：                                                │
│  ├─ 固定的数据包模式                                            │
│  ├─ 可被流量分析识别                                            │
│  └─ 容易被检测                                                  │
│                                                                 │
│  Vision 模式：                                                  │
│  ├─ 随机化的数据包大小                                          │
│  ├─ 更真实的 TLS Application Data 模式                          │
│  ├─ 更难被流量分析                                              │
│  └─ 更好的抗检测能力                                            │
│                                                                 │
│  Vision 数据包：                                                 │
│  ├─ TLS Header: 5 bytes                                       │
│  ├─ Content Type: Application Data (0x17)                     │
│  ├─ 包大小: 随机化 (模拟真实 TLS)                               │
│  └─ payload: 实际数据                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 uTLS 库

Xray 使用 **uTLS** 库来模拟真实浏览器的 TLS 指纹：

```
uTLS 指纹模拟：

支持的指纹：
├─ Chrome
├─ Firefox
├─ Safari
├─ iOS Safari
├─ Android Chrome
└─ 随机浏览器

配置：
{
  "security": "reality",
  "realitySettings": {
    "fingerprint": "chrome"  // 模拟 Chrome TLS 指纹
  }
}

效果：
├─ JA3 指纹与 Chrome 一致
├─ GFW 无法通过 TLS 指纹识别
└─ 使用真实浏览器指纹库
```

---

## 5. Mux.Cool 多路复用

### 5.1 Mux.Cool 原理

**Mux.Cool** 是 Xray 的多路复用协议，允许在单个 TLS 连接上并发多个请求：

```
Mux.Cool 多路复用：

┌─────────────────────────────────────────────────────────────────┐
│                    Mux.Cool 工作原理                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  不使用 Mux.Cool：                                               │
│  ├─ 每个连接一个 TLS 握手                                       │
│  ├─ 每个连接独立                                               │
│  └─ 连接数多，握手开销大                                        │
│                                                                 │
│  使用 Mux.Cool：                                                │
│                                                                 │
│  TLS Connection                                                 │
│  ├─ Connection 1 ─┬─ Request A                                 │
│  │               ├─ Request B                                 │
│  │               └─ Request C                                 │
│  │                                                             │
│  ├─ Connection 2 ─┬─ Request D                                 │
│  │               └─ Request E                                 │
│  │                                                             │
│  └─ Connection 3 ── Request F                                 │
│                                                                 │
│  优势：                                                          │
│  ├─ 减少 TLS 握手次数                                          │
│  ├─ 降低延迟                                                    │
│  ├─ 减少连接数                                                 │
│  └─ 更难被检测（更像浏览器行为）                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 Mux.Cool 配置

```
Mux.Cool 配置：

服务端：
{
  "inbounds": [{
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "uuid"
      }],
      "mux": {
        "enabled": true,
        "concurrency": 8
      }
    }
  }]
}

客户端：
{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "server.com",
        "port": 443,
        "users": [{"id": "uuid"}]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls",
      "tlsSettings": {
        "serverName": "server.com"
      }
    },
    "mux": {
      "enabled": true,
      "concurrency": 8
    }
  }]
}

参数说明：
├─ concurrency: 每个连接的最大复用数
├─ 建议值: 8-16
└─ 过高可能导致性能问题
```

---

## 6. Trojan-Go 协议融合

### 6.1 Trojan-Go in Xray

Xray 完整支持 Trojan-Go 协议：

```
Xray 支持的 Trojan 功能：

┌─────────────────────────────────────────────────────────────────┐
│                    Trojan-Go 功能支持                            │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Xray 原生支持：                                                │
│  ├─ Trojan 协议（与 Trojan-Go 兼容）                            │
│  ├─ WebSocket 传输                                              │
│  ├─ TLS 混淆                                                   │
│  ├─ 协议自动检测                                               │
│  └─ 完整 Trojan-Go 功能集                                       │
│                                                                 │
│  配置示例：                                                      │
│                                                                 │
│  {                                                              │
│    "protocol": "trojan",                                       │
│    "settings": {                                               │
│      "clients": [{                                             │
│        "password": "your-password"                             │
│      }],                                                        │
│      "fallbacks": [{                                           │
│        "dest": "127.0.0.1:80"                                  │
│      }]                                                         │
│    },                                                           │
│    "streamSettings": {                                         │
│      "network": "tcp",                                         │
│      "security": "tls"                                         │
│    }                                                           │
│  }                                                              │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 Fallback 配置

Trojan 的 **Fallback** 机制允许服务器在 Trojan 协议之外提供正常 HTTPS 服务：

```
Fallback 配置：

{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "trojan",
    "settings": {
      "clients": [{
        "password": "your-password"
      }],
      "fallbacks": [
        {
          "alpn": "http/1.1",
          "dest": "127.0.0.1:8080"  // Nginx/HTTP 服务
        },
        {
          "alpn": "h2",
          "dest": "127.0.0.1:8443"  // HTTP/2 服务
        }
      ]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "tls"
    }
  }]
}

工作原理：
├─ TLS 握手时检测 ALPN
├─ 如果是未知协议 ──▶ 转发到 fallback 目标
├─ 如果是 Trojan 流量 ──▶ 处理代理请求
└─ GFW 无法区分 Trojan 和正常 HTTPS
```

---

## 7. 性能对比

### 7.1 协议性能对比

```
协议性能（单连接吞吐量）：

测试环境：千兆网络，延迟 50ms

┌─────────────────────────────────────────────────────────────────┐
│                        吞吐量对比                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Protocol              │ Throughput    │ Latency               │
│  ─────────────────────┼───────────────┼───────────────        │
│  Trojan (TLS)          │ ~800 Mbps     │ 3-5 ms                │
│  VLESS+XTLS            │ ~900 Mbps     │ 2-4 ms                │
│  VLESS+XTLS+Vision     │ ~850 Mbps     │ 3-5 ms                │
│  Reality               │ ~900 Mbps     │ 2-4 ms                │
│  Shadowsocks (AEAD)    │ ~700 Mbps     │ 3-5 ms                │
│                                                                 │
│  说明：                                                          │
│  ├─ Xray 使用 Go 编写，性能优秀                                  │
│  ├─ Reality 与 XTLS 性能相近                                    │
│  └─ TLS 加解密是主要开销                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 CPU 开销对比

```
CPU 开销（单连接）：

┌─────────────────────────────────────────────────────────────────┐
│                        CPU 开销对比                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Protocol              │ CPU Usage   │ AES-NI Usage            │
│  ─────────────────────┼─────────────┼───────────────          │
│  Trojan (TLS 1.3)      │ 2-3%       │ Yes                     │
│  VLESS+XTLS           │ 2-3%       │ Yes                     │
│  Reality              │ 2-3%       │ Yes                     │
│  Shadowsocks (ChaCha) │ 3-4%       │ No (软件计算)             │
│                                                                 │
│  优化建议：                                                      │
│  ├─ 使用支持 AES-NI 的 CPU                                      │
│  ├─ 启用 TLS硬件加速                                            │
│  └─ 适当限制 mux 并发数                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. 配置模板

### 8.1 VLESS + XTLS Reality 配置

```
完整 Reality 配置模板：

服务端（server.json）：

{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "uuid-here",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "dest": "www.microsoft.com:443",
        "xver": 0,
        "serverNames": [
          "www.microsoft.com",
          "www.amazon.com",
          "www.apple.com"
        ],
        "privateKey": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
        "shortIds": ["0123456789abcdef"]
      }
    }
  }],
  "outbounds": [{
    "protocol": "freedom",
    "tag": "direct"
  }]
}

生成密钥：
xray x25519

客户端（client.json）：

{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": 1080,
    "protocol": "socks"
  }],
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "your-server.com",
        "port": 443,
        "users": [{
          "id": "uuid-here",
          "flow": "xtls-rprx-vision"
        }]
      }]
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "fingerprint": "chrome",
        "serverNames": ["www.microsoft.com"],
        "shadowServerId": 0,
        "shortId": "0123456789abcdef"
      }
    }
  }]
}
```

### 8.2 VLESS + WebSocket + TLS + CDN

```
CDN 配置模板：

服务端：

{
  "inbounds": [{
    "port": 443,
    "listen": "0.0.0.0",
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "uuid-here"
      }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/vless-ws"
      },
      "tlsSettings": {
        "serverName": "your-cdn-domain.com",
        "alpn": ["h2", "http/1.1"]
      }
    }
  }]
}

客户端：

{
  "outbounds": [{
    "protocol": "vless",
    "settings": {
      "vnext": [{
        "address": "your-cdn-domain.com",
        "port": 443,
        "users": [{
          "id": "uuid-here"
        }]
      }]
    },
    "streamSettings": {
      "network": "ws",
      "wsSettings": {
        "path": "/vless-ws",
        "headers": {
          "Host": "your-origin-domain.com"
        }
      }
    }
  }]
}
```

---

## 9. 总结

```
Xray 核心要点：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  项目定位：                                                      │
│  ├─ V2Ray 的高性能分支                                          │
│  ├─ RPRX 主导开发                                              │
│  └─ 当前最活跃的翻墙框架                                        │
│                                                                 │
│  核心协议：                                                      │
│  ├─ VLESS+XTLS：完整 TLS 伪装                                  │
│  ├─ Reality：完全去除 SNI 指纹                                  │
│  ├─ Vision：更好的流量伪装                                      │
│  └─ Trojan-Go：完整兼容                                         │
│                                                                 │
│  独有特性：                                                      │
│  ├─ uTLS 指纹模拟                                              │
│  ├─ Mux.Cool 多路复用                                          │
│  ├─ Fallback 分流                                              │
│  └─ geoip/geosite 路由                                        │
│                                                                 │
│  性能：                                                          │
│  ├─ Go 编写，性能优秀                                           │
│  ├─ TLS 硬件加速支持                                           │
│  └─ 单连接可达 900+ Mbps                                       │
│                                                                 │
│  当前推荐配置：                                                  │
│  ├─ Reality + Vision（最高安全性）                             │
│  ├─ 或 VLESS + WebSocket + TLS + CDN                          │
│  └─ 配合 Mux.Cool 使用                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Xray 是目前最先进的翻墙平台之一，其 Reality 协议代表了翻墙技术的最新进展。对于追求最高安全性和性能的用户，Xray 是首选方案。

---

## 参考资料

1. Xray. "Xray Core." github.com/XTLS
2. RPRX. "XTLS Vision." Official Documentation.
3. Reality Protocol. "Specification."
4. uTLS. " TLS Fingerprint Library." GitHub Repository.
