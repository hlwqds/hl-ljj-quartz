---
title: "VPN 技术深度探索 (三十五)：gost 代理工具"
date: 2026-04-13
tags: [vpn, series, gost, go-shadowsocks2, proxy-chain, load-balancing]
description: "gost 代理工具深度解析——Go 语言编写的高性能代理、go-shadowsocks2、代理链（chain）、负载均衡、多种协议转发与组合"
---

> [!info] VPN 技术深度探索系列 0. [[vpn-deep-dive|全栈学习路径总览]]
>
> 1. [[ch34-http-proxy|第三十四章：HTTP Proxy]]
> 2. **第三十五章：gost 代理工具**
> 3. [[ch36-sdp-architecture|第三十六章：SDP 软件定义边界]]

---

## 1. 概述：gost 简介

**gost**（Go Shadowsocks Tunnel）是使用 Go 语言编写的高性能代理工具，由 ginuerzh 等开发。gost 最初是 go-shadowsocks2 的 fork，现已发展成功能完善的代理瑞士军刀：

```
gost 核心特点：

┌─────────────────────────────────────────────────────────────────┐
│                      gost 功能概览                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  协议支持：                                                      │
│  ├─ SOCKS4/SOCKS4A/SOCKS5                                        │
│  ├─ HTTP/HTTPS 代理                                              │
│  ├─ Shadowsocks (AEAD)                                          │
│  ├─ ShadowsocksR（协议混淆）                                      │
│  ├─ VMess/VLESS（V2Ray 协议）                                    │
│  ├─ Trojan                                                     │
│  ├─ WireGuard                                                  │
│  ├─ TLS 隧道                                                    │
│  └─ TCP/UDP 端口转发                                            │
│                                                                 │
│  核心能力：                                                      │
│  ├─ 代理链（Chain）：多跳串联代理                                 │
│  ├─ 负载均衡：多种算法                                            │
│  ├─ 域名解析：远程/本地/缓存                                      │
│  ├─ 访问控制：ACL、IP 黑白名单                                    │
│  └─ 统计：流量、连接数                                            │
│                                                                 │
│  性能特点：                                                      │
│  ├─ Go 语言：高并发、低内存                                      │
│  ├─ 支持数千并发连接                                             │
│  └─ 支持 TLS 1.3                                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. 安装与基本配置

### 2.1 安装方式

```
gost 安装：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 安装方法                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 二进制下载（推荐）：                                          │
│                                                                 │
│  # Linux x86_64                                                │
│  curl -fsSL https://github.com/go-gost/gost/releases/download/  │
│    v3.0.0/gost_3.0.0_linux_amd64.tar.gz | tar xz              │
│                                                                 │
│  # macOS                                                       │
│  brew install gost                                             │
│                                                                 │
│  2. Docker：                                                    │
│                                                                 │
│  docker run --rm -p 8080:8080 ghcr.io/go-gost/gost:latest      │
│                                                                 │
│  3. 源码编译：                                                   │
│                                                                 │
│  go install github.com/go-gost/gost/v3@latest                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 基本使用

```
gost 基本命令：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 基础用法                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 简单 SOCKS5 代理：                                            │
│                                                                 │
│  gost -L socks5://:1080                                         │
│              │                                                  │
│              └── 监听 1080 端口的 SOCKS5 代理                    │
│                                                                 │
│  2. 带认证的 SOCKS5：                                            │
│                                                                 │
│  gost -L socks5://user:pass@:1080                               │
│                                                                 │
│  3. HTTP 代理：                                                  │
│                                                                 │
│  gost -L http://:8080                                            │
│                                                                 │
│  4. Shadowsocks：                                               │
│                                                                 │
│  gost -L ss://aes-256-gcm:password@:8388                       │
│                                                                 │
│  5. 转发到远程代理：                                              │
│                                                                 │
│  gost -L socks5://:1080 -F socks5://remote-proxy:1080           │
│              │              │                                  │
│              │              └── 上游代理                         │
│              └── 本地代理入口                                    │
│                                                                 │
│  常用参数：                                                      │
│  ├─ -L: 本地监听地址                                            │
│  ├─ -F: 上游代理地址                                            │
│  ├─ -Lfile: 日志文件                                            │
│  └─ -trace: 详细调试日志                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. 代理链（Chain）详解

### 3.1 代理链原理

代理链是 gost 最强大的功能之一，允许串联多个代理节点：

```
gost 代理链架构：

┌─────────────────────────────────────────────────────────────────┐
│                    多级代理链                                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Client → L1 → L2 → L3 → Target                                 │
│           │     │     │                                         │
│           │     │     └── 代理节点 3（最后一跳）                   │
│           │     └── 代理节点 2                                    │
│           └── 代理节点 1（入口）                                   │
│                                                                 │
│  数据流向：                                                      │
│  1. Client 连接到 L1（本地代理）                                  │
│  2. L1 连接到 L2，转发数据                                        │
│  3. L2 连接到 L3，转发数据                                        │
│  4. L3 连接到目标服务器                                          │
│                                                                 │
│  代理链用途：                                                    │
│  ├─ 隐私保护：每跳只知道上一跳                                    │
│  ├─ 突破限制：串联多个代理                                        │
│  ├─ 流量分配：不同流量走不同路径                                   │
│  └─ 故障转移：某节点不可用时自动切换                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 代理链配置示例

````
gost 代理链配置：

┌─────────────────────────────────────────────────────────────────┐
│                    gost chain 配置                               │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  方式一：命令行链式代理                                            │
│                                                                 │
│  gost -L socks5://:1080 \                                       │
│       -F socks5://proxy1.example.com:1080 \                   │
│       -F socks5://proxy2.example.com:1080 \                   │
│       -F http://proxy3.example.com:8080                        │
│                                                                 │
│  说明：                                                         │
│  ├─ -F 可以多次使用，形成链                                      │
│  ├─ 按顺序连接：1080 → proxy1 → proxy2 → proxy3 → 目标           │
│  └─ 最后一级可以是任何协议                                        │
│                                                                 │
│  方式二：配置文件（复杂场景）                                     │
│                                                                 │
│  gost -C config.yaml                                            │
│                                                                 │
│  config.yaml:                                                  │
│  ```                                                           │
│  workers: 4                     # 工作线程数                     │
│  maxFD: 65535                   # 最大文件描述符                  │
│                                                                 │
│  socks5:                        # SOCKS5 入口                    │
│    - name: local               # 命名节点                        │
│      addr: :1080               # 监听地址                        │
│      auth:                     # 认证配置                        │
│        username: user          │
│        password: pass          │
│      chain:                    # 代理链                          │
│        selector:              # 节点选择器                      │
│          - name: proxy1       # 第一跳                          │
│            socks5:             # 协议类型                        │
│              addr: proxy1.example.com:1080                      │
│              secure: false     # TLS                            │
│          - name: proxy2        # 第二跳                          │
│            http:               # HTTP 代理                      │
│              addr: proxy2.example.com:8080                      │
│  ```                                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
````

### 3.3 代理链选择策略

```
gost 节点选择策略：

┌─────────────────────────────────────────────────────────────────┐
│                    代理链策略                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 顺序（Sequential）：                                         │
│  ├─ 按配置顺序依次尝试                                          │
│  └─ 第一可用节点                                               │
│                                                                 │
│  2. 随机（Random）：                                            │
│  ├─ 随机选择节点                                                │
│  └─ 每次请求可能不同                                            │
│                                                                 │
│  3. 轮询（RoundRobin）：                                        │
│  ├─ 依次使用每个节点                                            │
│  └─ 负载均衡                                                   │
│                                                                 │git
│  4. 备用（Failover）：                                          │
│  ├─ 主节点不可用时切换到备用                                     │
│  └─ 支持健康检查                                                │
│                                                                 │
│  5. 域名分流（Domain）：                                        │
│  ├─ 不同域名走不同节点                                          │
│  └─ 基于规则的智能路由                                          │
│                                                                 │
│  配置示例：                                                     │
│                                                                 │
│  chain:                                                        │
│    selector:                                                  │
│      strategy: roundrobin         # 轮询策略                    │
│      targets:                                                  │
│        - name: us-proxy                                  │
│          socks5:                                            │
│            addr: us.example.com:1080                         │
│        - name: sg-proxy                                      │
│          socks5:                                             │
│            addr: sg.example.com:1080                         │
│        - name: jp-proxy                                      │
│          socks5:                                             │
│            addr: jp.example.com:1080                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 负载均衡

### 4.1 负载均衡策略

gost 支持多种负载均衡算法，将请求分发到多个代理节点：

```
gost 负载均衡：

┌─────────────────────────────────────────────────────────────────┐
│                    负载均衡算法                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 最小连接数（LeastConn）：                                    │
│  ├─ 选择连接数最少的节点                                         │
│  ├─ 动态感知负载                                                │
│  └─ 适合长连接                                                  │
│                                                                 │
│  2. 轮询（RoundRobin）：                                        │
│  ├─ 依次分配给每个节点                                          │
│  ├─ 简单高效                                                    │
│  └─ 适合短连接                                                  │
│                                                                 │
│  3. 随机（Random）：                                            │
│  ├─ 随机选择节点                                                │
│  ├─ 无状态                                                    │
│  └─ 统计均匀时效果好                                            │
│                                                                 │
│  4. 加权（Weight）：                                            │
│  ├─ 按权重比例分配                                              │
│  ├─ 性能好的节点权重高                                          │
│  └─ 需要手动配置权重                                            │
│                                                                 │
│  5. 延迟（Latency）：                                           │
│  ├─ 选择延迟最低的节点                                          │
│  ├─ 需要定期探测延迟                                            │
│  └─ 适合对延迟敏感的应用                                        │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 负载均衡配置

```
负载均衡配置示例：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 负载均衡配置                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  socks5:                                                       │
│    - name: balancer                                            │
│      addr: :1080                                               │
│      chain:                                                    │
│        selector:                                              │
│          strategy: leastconn          # 最小连接                │
│          maxConn: 1000               # 单节点最大连接          │
│          targets:                                            │
│            - name: proxy1                                    │
│              weight: 3                 # 权重 3                 │
│              socks5:                                          │
│                addr: proxy1.example.com:1080                  │
│            - name: proxy2                                    │
│              weight: 2                 # 权重 2                 │
│              socks5:                                          │
│                addr: proxy2.example.com:1080                  │
│            - name: proxy3                                    │
│              weight: 1                 # 权重 1                 │
│              socks5:                                          │
│                addr: proxy3.example.com:1080                  │
│                                                                 │
│  权重分配（3:2:1）：                                            │
│  ├─ proxy1: 50% 流量                                          │
│  ├─ proxy2: 33% 流量                                          │
│  └─ proxy3: 17% 流量                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 5. 协议组合与转发

### 5.1 多种协议组合

gost 的核心优势是能够组合不同协议：

```
gost 协议组合：

┌─────────────────────────────────────────────────────────────────┐
│                    协议转发链路                                   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  SOCKS5 → Shadowsocks → TLS → VMess → Target                  │
│    │          │          │       │                             │
│    │          │          │       └── V2Ray 协议                 │
│    │          │          └── TLS 隧道加密                       │
│    │          └── 加密流量                                       │
│    └── 本地入口                                                 │
│                                                                 │
│  配置示例：                                                     │
│                                                                 │
│  gost -L socks5://:1080 \                                      │
│       -F ss://aes-256-gcm:pass@ss-proxy:8388 \                 │
│       -F tls://tls-proxy:443 \                                 │
│       -F vmess://uuid@vmess-proxy:10086                       │
│                                                                 │
│  常见协议组合：                                                 │
│                                                                 │
│  1. 安全增强链：                                                │
│  HTTP → Shadowsocks → TLS                                      │
│  │     │            └── TLS 加密，伪装正常 HTTPS                │
│  │     └── 加密原始流量                                         │
│  └── 常见代理协议                                              │
│                                                                 │
│  2. 翻墙优化链：                                                │
│  SOCKS5 → vmess:// + WebSocket + TLS → CDN → 目标             │
│                                                                 │
│  3. 企业出网链：                                                │
│  SOCKS5 → HTTP Proxy → 目标                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 端口转发

gost 支持 TCP/UDP 端口转发：

```
gost 端口转发：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 端口转发                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. TCP 端口转发：                                               │
│                                                                 │
│  gost -L tcp://:2222/:22                                        │
│         │      │    │                                           │
│         │      │    └── 目标地址                                 │
│         │      └── 本地监听端口                                  │
│         └── TCP 协议                                            │
│                                                                 │
│  # 效果：将本机的 2222 端口转发到 localhost:22                   │
│                                                                 │
│  2. UDP 端口转发：                                               │
│                                                                 │
│  gost -L udp://:5353/:53                                        │
│                                                                 │
│  # 效果：将本机的 UDP 5353 转发到 localhost:53 DNS               │
│                                                                 │
│  3. 端口转发 + 代理链：                                          │
│                                                                 │
│  gost -L tcp://:2222/:22 -F socks5://proxy:1080                │
│                                                                 │
│  # 通过代理转发 SSH 连接                                         │
│                                                                 │
│  4. 透明代理：                                                   │
│                                                                 │
│  gost -L redirect://:8889 -F http://proxy:8080                  │
│                                                                 │
│  # redirect 模式：抓取流量并转发                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 6. DNS 处理

### 6.1 DNS 解析策略

gost 支持灵活的 DNS 处理，防止 DNS 泄露：

```
gost DNS 处理：

┌─────────────────────────────────────────────────────────────────┐
│                    DNS 解析策略                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  DNS 模式：                                                     │
│                                                                 │
│  1. 本地 DNS（Local）：                                          │
│  ├─ 使用系统默认 DNS                                            │
│  ├─ 可能被投毒                                                  │
│  └─ 有 DNS 泄露风险                                             │
│                                                                 │
│  2. 远程 DNS（Remote）：                                        │
│  ├─ 通过代理服务器解析 DNS                                       │
│  ├─ 避免 DNS 投毒                                              │
│  └─ 推荐翻墙使用                                                │
│                                                                 │
│  3. 缓存 DNS（Cache）：                                         │
│  ├─ 缓存解析结果                                                │
│  └─ 加速重复查询                                                │
│                                                                 │
│  4. DoH/DoT（加密 DNS）：                                       │
│  ├─ DoH: DNS over HTTPS                                        │
│  ├─ DoT: DNS over TLS                                         │
│  └─ 防止 DNS 监控和篡改                                          │
│                                                                 │
│  配置示例：                                                     │
│                                                                 │
│  gost -L socks5://:1080 \                                      │
│       -F ss://... \                                            │
│       --dns-remote-type=tcp          # 远程 DNS 使用 TCP       │
│       --dns-remote=8.8.8.8:53        # 远程 DNS 服务器          │
│       --dns-cache                    # 启用 DNS 缓存            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 高级配置

### 7.1 完整配置示例

````
gost 完整配置示例：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 完整配置                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  文件：config.yaml                                             │
│                                                                 │
│  ```                                                           │
│  # 全局设置                                                     │
│  workers: 8                      # Goroutine 数量              │
│  maxFD: 65535                    # 最大文件描述符              │
│  stdout: /var/log/gost.log       # 日志输出                    │
│  logLevel: info                  # 日志级别                    │
│                                                                 │
│  # 入口定义                                                     │
│  socks5:                                                       │
│    - name: proxy-in             # SOCKS5 入口                  │
│      addr: :1080                # 监听地址                     │
│      auth:                      # 认证                         │
│        username: user                                          │
│        password: pass123                                        │
│      udp: true                  # 启用 UDP 支持               │
│      chain:                    # 代理链                        │
│        name: main                                              │
│        selector:                # 选择器                        │
│          strategy: roundrobin   # 轮询                         │
│          maxConn: 500           # 单节点最大连接               │
│          targets:                                              │
│            - name: proxy-us     # 美国代理                     │
│              weight: 3          # 权重                         │
│              socks5:                                          │
│                addr: us.example.com:1080                       │
│                secure: false    # 不验证 TLS                   │
│            - name: proxy-sg     # 新加坡代理                   │
│              weight: 2          # 权重                         │
│              socks5:                                          │
│                addr: sg.example.com:1080                       │
│            - name: proxy-jp     # 日本代理                     │
│              weight: 1          # 权重                         │
│              socks5:                                          │
│                addr: jp.example.com:1080                       │
│                                                                 │
│  http:                                                         │
│    - name: http-in             # HTTP 代理入口                 │
│      addr: :8080               # 监听地址                      │
│      auth:                                                       │
│        username: admin                                          │
│        password: admin123                                         │
│      chain:                                                       │
│        name: main              # 复用 socks5 的 chain          │
│                                                                 │
│  # 转发规则                                                     │
│  forward:                                                        │
│    - name: ssh-forward        # SSH 转发                       │
│      socks5: proxy-in                                          │
│      tcp:                                                       │
│        - local: :2222                                          │
│          remote: :22                                           │
│                                                                 │
│  # ACL 规则                                                     │
│  access:                                                        │
│    - name: acl                                                 │
│      rules:                                                     │
│        - ip: 192.168.0.0/16    # 允许内网                       │
│          allow: true                                          │
│        - ip: 10.0.0.0/8                                        │
│          allow: true                                          │
│        - domain: *.internal.com                                │
│          allow: true                                          │
│        - domain: blocked.com                                  │
│          allow: false         # 拒绝                          │
│  ```                                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
````

### 7.2 TLS 配置

```
gost TLS 配置：

┌─────────────────────────────────────────────────────────────────┐
│                    gost TLS 配置                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 服务端 TLS：                                                │
│                                                                 │
│  gost -L socks5://:1080 \                                       │
│       --tls-ca=/path/to/ca.crt \                               │
│       --tls-cert=/path/to/cert.pem \                          │
│       --tls-key=/path/to/key.pem                               │
│                                                                 │
│  2. 客户端验证 TLS：                                            │
│                                                                 │
│  gost -L socks5://:1080 \                                       │
│       -F socks5://server:1080 \                                │
│       --tls-ca=/path/to/ca.crt \                               │
│       --tls-verify                     # 验证服务器证书         │
│                                                                 │
│  3. TLS 伪装：                                                  │
│                                                                 │
│  gost -L tls://:443 \                                          │
│       --tls-cert=/path/to/cert.pem \                          │
│       --tls-key=/path/to/key.pem \                             │
│       --tls-sni=www.example.com \                             │
│       -F ss://aes-256-gcm:pass@:8388                          │
│                                                                 │
│       └── 443 端口 TLS 伪装，内部转发到 Shadowsocks              │
│                                                                 │
│  4. TLS 1.3 配置：                                             │
│                                                                 │
│  gost -L socks5://:1080 \                                       │
│       -F tls://server:443 \                                    │
│       --tls-min=1.3 \               # 最低 TLS 1.3             │
│       --tls-ciphers=TLS_AES_256_GCM_SHA384                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 8. 与其他工具对比

```
gost vs 常见代理工具对比：

┌─────────────────┬──────────┬──────────┬──────────┬──────────┐
│ 特性            │ gost     │ ss-local │ V2Ray    │ Clash    │
├─────────────────┼──────────┼──────────┼──────────┼──────────┤
│ 开发语言        │ Go       │ C        │ Go       │ Go       │
│ 协议支持        │ 极多      │ SS 专用  │ 极多      │ 较多      │
│ 代理链          │ ✓        │ ✗        │ ✓        │ ✗        │
│ 负载均衡        │ ✓        │ ✗        │ 部分      │ 部分      │
│ 配置文件        │ YAML/CLI │ JSON     │ JSON     │ YAML     │
│ 规则分流        │ ✓        │ ✗        │ ✓        │ ✓        │
│ WebSocket      │ ✓        │ 插件     │ ✓        │ ✓        │
│ TLS 伪装        │ ✓        │ 插件     │ ✓        │ ✓        │
│ XTLS/Reality   │ ✗        │ ✗        │ ✓        │ ✓        │
│ 性能            │ 高       │ 高       │ 中       │ 高       │
│ 配置难度        │ 中       │ 低       │ 高       │ 中       │
└─────────────────┴──────────┴──────────┴──────────┴──────────┘

选择建议：
├─ 简单 SS 翻墙 → ss-local + v2ray-plugin
├─ 多协议 + 代理链 → gost
├─ 复杂规则 + 订阅 → Clash
└─ 企业级 + VMess/VLESS → V2Ray
```

---

## 9. 部署与运维

### 9.1 systemd 服务配置

```
gost systemd 服务：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 服务配置                                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  /etc/systemd/system/gost.service:                             │
│                                                                 │
│  [Unit]                                                         │
│  Description=gost Proxy Server                                 │
│  After=network.target                                          │
│                                                                 │
│  [Service]                                                      │
│  Type=simple                                                    │
│  ExecStart=/usr/local/bin/gost -C /etc/gost/config.yaml       │
│  Restart=always                                                │
│  RestartSec=5                                                 │
│  User=gost                                                     │
│  Group=gost                                                    │
│  LimitNOFILE=65535                                             │
│                                                                 │
│  [Install]                                                      │
│  WantedBy=multi-user.target                                     │
│                                                                 │
│  配置用户：                                                     │
│  useradd -r -s /usr/sbin/nologin gost                          │
│  mkdir /etc/gost                                               │
│  chown gost:gost /etc/gost                                     │
│                                                                 │
│  启动服务：                                                     │
│  systemctl daemon-reload                                       │
│  systemctl enable gost                                         │
│  systemctl start gost                                         │
│  systemctl status gost                                         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 9.2 Docker 部署

```
gost Docker 部署：

┌─────────────────────────────────────────────────────────────────┐
│                    gost Docker 配置                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Docker Compose：                                            │
│                                                                 │
│  version: '3'                                                   │
│  services:                                                      │
│    gost:                                                        │
│      image: ghcr.io/go-gost/gost:latest                        │
│      container_name: gost                                      │
│      restart: always                                           │
│      ports:                                                     │
│        - "1080:1080/tcp"         # SOCKS5                       │
│        - "8080:8080/tcp"         # HTTP                         │
│      volumes:                                                    │
│        - ./config.yaml:/etc/gost/config.yaml                  │
│        - ./logs:/var/log/gost                                  │
│      command: -C /etc/gost/config.yaml                         │
│                                                                 │
│  2. 带 TLS 的 Docker 配置：                                      │
│                                                                 │
│  version: '3'                                                   │
│  services:                                                      │
│    gost:                                                        │
│      image: ghcr.io/go-gost/gost:latest                        │
│      ports:                                                     │
│        - "443:443/tcp"            # TLS 入口                    │
│      volumes:                                                    │
│        - ./config.yaml:/etc/gost/config.yaml                  │
│        - ./certs:/etc/gost/certs                              │
│      command: >                                                │
│        -C /etc/gost/config.yaml                               │
│        --tls-ca=/etc/gost/certs/ca.crt                        │
│        --tls-cert=/etc/gost/certs/cert.pem                   │
│        --tls-key=/etc/gost/certs/key.pem                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 9.3 日志与监控

```
gost 日志与监控：

┌─────────────────────────────────────────────────────────────────┐
│                    gost 日志配置                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  日志级别：                                                     │
│  ├─ debug: 详细调试                                             │
│  ├─ info: 信息（默认）                                          │
│  ├─ warn: 警告                                                  │
│  └─ error: 错误                                                 │
│                                                                 │
│  日志格式：                                                     │
│  logLevel: info                                                 │
│  logFormat: json           # JSON 格式便于收集                  │
│                                                                 │
│  日志示例（JSON）：                                             │
│                                                                 │
│  {                                                              │
│    "time": "2024-01-15T10:30:00Z",                              │
│    "level": "info",                                            │
│    "msg": "connection established",                            │
│    "src": "192.168.1.100:54321",                               │
│    "dst": "93.184.216.34:443",                                 │
│    "in": "socks5",                                              │
│    "out": "ss",                                                 │
│    "node": "proxy-us"                                          │
│  }                                                              │
│                                                                 │
│  集成 Prometheus：                                              │
│                                                                 │
│  gost -L socks5://:1080 \                                       │
│       --metrics=:9090 \              # 监控端口                  │
│       --metrics-path=/metrics                                 │
│                                                                 │
│  Prometheus 指标：                                             │
│  ├─ gost_connections_total                                    │
│  ├─ gost_traffic_bytes                                        │
│  └─ gost_latency_seconds                                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```
