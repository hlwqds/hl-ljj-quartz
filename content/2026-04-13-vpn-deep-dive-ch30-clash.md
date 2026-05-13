---
title: "VPN 技术深度探索 (三十)：Clash 生态"
date: 2026-04-13
tags: [vpn, series, clash, proxy, gateway, rules, subscription, mihomo]
description: "Clash 生态深度解析——Clash/Premium/Meta 客户端对比、规则分流策略、订阅制管理、mihomo/Clash.Meta 项目、配置模板与 Surge 兼容"
---

> [!info] VPN 技术深度探索系列
> 0. [[2026-04-13-vpn-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-vpn-deep-dive-ch29-xray|Xray 核心]]
> 2. **第三十章：Clash 生态**
> 3. [[2026-04-13-vpn-deep-dive-ch31-tls-cdn|第三十一章：TLS 伪装与 CDN]]
> 4. [[2026-04-13-vpn-deep-dive-ch32-tor-network|第三十二章：Tor 网络]]

---

## 1. 概述：Clash 定位

**Clash** 是 dreamater（华翔）于 2017 年开发的代理客户端，定位是**通用代理网关和规则分流引擎**。与 V2Ray/Xray 等服务端代理不同，Clash 更侧重于**客户端的规则管理和流量分流**。

```
Clash vs V2Ray/Xray：

┌─────────────────────────────────────────────────────────────────┐
│                      定位对比                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  V2Ray/Xray（服务端代理）：                                      │
│  ├─ 部署在服务器端                                             │
│  ├─ 处理代理请求                                               │
│  ├─ 协议实现完善                                               │
│  └─ 路由功能相对简单                                            │
│                                                                 │
│  Clash（代理客户端/网关）：                                      │
│  ├─ 部署在用户终端                                             │
│  ├─ 作为代理入口                                                │
│  ├─ 强大的规则分流                                              │
│  └─ 支持多种协议                                                │
│                                                                 │
│  配合使用：                                                      │
│  ├─ V2Ray/Xray/Trojan 作为服务端                               │
│  ├─ Clash 作为客户端分流                                        │
│  └─ 各司其职，配合使用                                          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 2. Clash 核心架构

### 2.1 工作模式

Clash 支持多种工作模式：

```
Clash 工作模式：

┌─────────────────────────────────────────────────────────────────┐
│                      Clash 工作模式                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Proxy Mode（代理模式）：                                    │
│     ├─ 系统代理：仅代理设置代理的流量                             │
│     ├─ 适用于浏览器等单个应用                                    │
│     └─ 其他应用不受影响                                          │
│                                                                 │
│  2. Gateway Mode（网关模式）：                                   │
│     ├─ TUN/TAP 模式                                            │
│     ├─ 接管全部系统流量                                         │
│     ├─ 适合全局代理                                            │
│     └─ 需要 TUN 驱动支持                                        │
│                                                                 │
│  3. Direct Mode（直连模式）：                                    │
│     └─ 所有流量直连，不走代理                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 组件架构

```
Clash 核心组件：

┌─────────────────────────────────────────────────────────────────┐
│                      Clash 架构                                 │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  inbound（入口）：                                              │
│  ├─ HTTP 代理端口                                               │
│  ├─ SOCKS5 代理端口                                             │
│  ├─ TUN/TAP 虚拟网卡                                           │
│  └─ Redir（Linux）                                             │
│                                                                 │
│  outbound（出口）：                                             │
│  ├─ Shadowsocks                                               │
│  ├─ VMess/VLESS                                               │
│  ├─ Trojan                                                    │
│  ├─ WireGuard                                                │
│  ├─ HTTP/SOCKS5 上游                                          │
│  └─ Direct（直连）                                             │
│                                                                 │
│  规则引擎：                                                     │
│  ├─ DOMAIN 规则                                                │
│  ├─ DOMAIN-SUFFIX                                             │
│  ├─ DOMAIN-KEYWORD                                            │
│  ├─ IP-CIDR                                                   │
│  ├─ GEOIP                                                      │
│  ├─ PROCESS-NAME（Premium）                                    │
│  └─ RULE-SET（Meta）                                          │
│                                                                 │
│  DNS 服务器：                                                   │
│  ├─ 远程 DNS（通过代理）                                        │
│  ├─ 本地 DNS（防污染）                                          │
│  └─ DNS 劫持                                                   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Clash 分支版本

### 3.1 分支对比

Clash 有多个活跃分支：

```
Clash 分支版本：

┌─────────────────────────────────────────────────────────────────┐
│                      Clash 版本对比                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Clash（Original）：                                             │
│  ├─ 作者：dreamater                                             │
│  ├─ 状态：停止维护                                             │
│  ├─ 基础规则引擎                                               │
│  └─ 已不推荐使用                                                │
│                                                                 │
│  Clash Premium：                                                │
│  ├─ Clash 商业版                                                │
│  ├─ 增强：TUN 模式、rule providers                             │
│  ├─ 性能优化                                                    │
│  ├─ 作者提供二进制，不开源                                       │
│  └─ 价格：$9.99/月                                             │
│                                                                 │
│  Clash.Meta / Mihomo：                                         │
│  ├─ Clash 开源分支                                              │
│  ├─ 作者：MetaCube (@Metacubed)                                │
│  ├─ 完全开源                                                    │
│  ├─ 兼容 Clash 配置                                            │
│  ├─ 额外功能：Script、rule providers、TailScale               │
│  └─ 推荐使用                                                    │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Clash.Meta 功能

```
Clash.Meta 独有特性：

┌─────────────────────────────────────────────────────────────────┐
│                    Clash.Meta 功能                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Script 脚本支持：                                           │
│     ├─ 使用 JavaScript 编写规则                                 │
│     ├─ 动态规则判断                                            │
│     └─ 示例：基于时间自动切换节点                                │
│                                                                 │
│  2. Rule Providers：                                           │
│     ├─ 外部规则订阅                                            │
│     ├─ 增量更新                                                │
│     └─ 更好的规则管理                                           │
│                                                                 │
│  3. Sniff：                                                     │
│     ├─ TLS 域名嗅探                                            │
│     ├─ HTTP Host 嗅探                                          │
│     └─ 更好的分流精度                                          │
│                                                                 │
│  4. GeoIP 增强：                                               │
│     ├─ 支持更多数据库                                           │
│     └─ 自定义 IP 规则                                          │
│                                                                 │
│  5. Tailscale 支持：                                           │
│     ├─ 集成 Tailscale                                          │
│     └─ 构建混合网络                                            │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

---

## 4. 规则系统

### 4.1 规则类型

Clash 支持多种规则类型：

```
Clash 规则类型：

┌─────────────────────────────────────────────────────────────────┐
│                      规则类型                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  DOMAIN：                                                       │
│    ├─ 精确域名匹配                                              │
│    └─ 示例：domain:google.com                                  │
│                                                                 │
│  DOMAIN-SUFFIX：                                               │
│    ├─ 域名后缀匹配                                              │
│    └─ 示例：domain-suffix:facebook.com                         │
│                                                                 │
│  DOMAIN-KEYWORD：                                              │
│    ├─ 域名关键字匹配                                            │
│    └─ 示例：domain-keyword:google                              │
│                                                                 │
│  DOMAIN-Regular Expression：                                   │
│    ├─ 域名正则匹配                                              │
│    └─ 示例：domain:^.*\.google\..*$                            │
│                                                                 │
│  IP-CIDR：                                                     │
│    ├─ IP 段匹配                                                 │
│    └─ 示例：ip-cidr:10.0.0.0/8,no-resolve                     │
│                                                                 │
│  GEOIP：                                                       │
│    ├─ 按国家/地区匹配                                           │
│    └─ 示例：geoip:cn                                           │
│                                                                 │
│  PROCESS-NAME（Premium）：                                     │
│    ├─ 进程名匹配（仅 TUN 模式）                                  │
│    └─ 示例：process-name:safari.exe                            │
│                                                                 │
│  RULE-SET（Meta）：                                            │
│    ├─ 外部规则集                                                │
│    └─ 示例：rule-set:category-ads,🛑 广告拦截                    │
│                                                                 │
│  SCRIPT（Meta）：                                               │
│    ├─ 脚本规则                                                 │
│    └─ 示例：script:hourly-rule                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.2 规则策略

每条规则关联一个策略组或代理：

```
规则策略：

┌─────────────────────────────────────────────────────────────────┐
│                      策略类型                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. Proxy（代理）：                                             │
│     ├─ DIRECT：直连                                            │
│     ├─ REJECT：拒绝                                            │
│     └─ Proxy-Name：指定代理节点                                 │
│                                                                 │
│  2. Proxy Group（代理组）：                                     │
│     │                                                          │
│     ├─ url-test：                                              │
│     │   ├─ 自动选择最快节点                                     │
│     │   ├─ 参数：url、interval                                 │
│     │   └─ 示例：对延迟敏感的流量                                │
│     │                                                          │
│     ├─ fallback：                                              │
│     │   ├─ 按顺序尝试，首个可用即用                              │
│     │   └─ 示例：主备切换                                        │
│     │                                                          │
│     ├─ load-balance：                                          │
│     │   ├─ 轮询分发                                            │
│     │   └─ 示例：负载均衡                                       │
│     │                                                          │
│     ├─ select：                                                │
│     │   ├─ 手动选择                                            │
│     │   └─ 用户界面选择                                         │
│     │                                                          │
│     └─ url-test + fallback 组合                                │
│         ├─ 自动测试 + 故障转移                                   │
│         └─ 示例：自动选择最优节点                               │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 4.3 规则示例

```
完整规则配置示例：

proxy-groups:
  # 主代理组（手动选择）
  - name: "Proxy"
    type: select
    proxies:
      -香港节点1
      -日本节点2
      -美国节点3

  # 自动选择最快
  - name: "Auto"
    type: url-test
    proxies:
      - 香港节点1
      - 日本节点2
      - 美国节点3
    url: "http://www.gstatic.com/generate_204"
    interval: 300

  # 主备切换
  - name: "Fallback"
    type: fallback
    proxies:
      - 香港节点1
      - 日本节点2
    url: "http://www.gstatic.com/generate_204"
    interval: 300

rules:
  # 广告拦截
  - RULE-SET,category-ads,REJECT

  # 国内网站直连
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,cn,DIRECT

  # 常用网站
  - DOMAIN-KEYWORD,google,Proxy
  - DOMAIN-KEYWORD,youtube,Proxy
  - DOMAIN-KEYWORD,twitter,Proxy
  - DOMAIN-KEYWORD,facebook,Proxy

  # Netflix 等流媒体
  - DOMAIN-SUFFIX,netflix.com,Auto
  - DOMAIN-SUFFIX,disneyplus.com,Auto

  # Telegram
  - DOMAIN-KEYWORD,telegram,Proxy
  - IP-CIDR,91.108.56.0/22,Proxy,no-resolve

  # 默认规则
  - MATCH,Proxy
```

---

## 5. 订阅系统

### 5.1 订阅制原理

Clash 支持通过订阅链接自动更新配置：

```
订阅制架构：

┌─────────────────────────────────────────────────────────────────┐
│                      订阅系统                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  1. 服务端                                                      │
│     ├─ 提供商运营的代理节点                                      │
│     ├─ 生成 Clash 配置                                           │
│     ├─ 提供订阅 URL（加密）                                      │
│     └─ 支持 Base64 编码加密                                     │
│                                                                 │
│  2. 客户端                                                      │
│     ├─ 定期拉取订阅 URL                                         │
│     ├─ 自动更新配置                                             │
│     ├─ 合并多个订阅（可选）                                      │
│     └─ 自动去重                                                 │
│                                                                 │
│  3. 订阅 URL 格式                                              │
│     https://api.example.com/clash                               │
│     https://api.example.com/clash?mu=1                          │
│                                                                 │
│  安全措施：                                                      │
│  ├─ URL 加密（Base64 或 AES）                                   │
│  ├─ 订阅 token                                                  │
│  └─ 有效期限制                                                  │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 5.2 订阅配置

```
Clash 订阅配置：

 Clash.Meta 中配置订阅：

proxy-providers:
  # 订阅提供
  provider1:
    type: http
    url: "https://api.example.com/clash"
    interval: 3600
    path: "./providers/provider1.yaml"
    health-check:
      enable: true
      url: "http://www.gstatic.com/generate_204"
      interval: 300
    # 代理名称过滤
    filter: "香港|Tokyo|Singapore"

  # 本地代理定义
proxies:
  - name: "手动节点1"
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: "password"

proxy-groups:
  - name: "Provider"
    type: select
    use:
      - provider1
```

### 5.3 订阅转换

```
订阅转换服务：

常用订阅转换服务：
├─ sub.sh
├─ clash.ishadow2.top
├─ acl4ssr
└─ 各类自建服务

转换功能：
├─ 格式转换：SS → Clash
├─ 规则合并：整合多个订阅
├─ 节点过滤：按关键字筛选
├─ 规则更新：自动更新规则到最新
└─ 加密混淆：URL 加密

自定义转换配置示例：
{
  "proxies": ["香港", "日本", "美国"],
  "domains": ["google.com", "netflix.com"],
  "excludes": ["美国-03"],
  "sort": true
}
```

---

## 6. TUN 模式

### 6.1 TUN 模式原理

Clash Premium/Meta 支持 TUN 模式，实现全局代理：

```
TUN 模式 vs 代理模式：

┌─────────────────────────────────────────────────────────────────┐
│                      TUN 模式原理                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  代理模式：                                                      │
│  ├─ 仅代理配置了代理的应用流量                                    │
│  ├─ 应用需要显式设置 SOCKS/HTTP 代理                             │
│  ├─ 系统代理：操作系统级别的代理设置                               │
│  └─ 问题：不是所有应用都支持代理                                  │
│                                                                 │
│  TUN 模式：                                                      │
│  ├─ 创建虚拟 TUN 网卡                                            │
│  ├─ 劫持全部系统流量                                             │
│  ├─ 在内核层面处理                                                │
│  └─ 所有应用自动走代理                                           │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 6.2 TUN 配置

```
Clash.Meta TUN 配置：

mixin:
  dns:
    enable: true
    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    nameserver:
      - 223.5.5.5
      - 119.29.29.29
    fallback:
      - 8.8.8.8
      - 1.1.1.1

tun:
  enable: true
  stack: system  # system / gvisor / lwip
  dns-hijack:
    - 8.8.8.8:53
    - 1.1.1.1:53
  auto-route: true  # 自动设置路由
  auto-detect-interface: true  # 自动检测出口网卡

# Clash.Meta 额外配置
sniff:
  enable: true
  override-destination: true
  tls-hijack: true
```

---

## 7. Clash 客户端

### 7.1 跨平台客户端

```
Clash 客户端生态：

┌─────────────────────────────────────────────────────────────────┐
│                      平台支持                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Windows：                                                       │
│  ├─ Clash for Windows (CFW)                                     │
│  ├─ Clash Verge                                                │
│  ├─ ClashN                            │
│  └─ Clash Meta 官方 GUI                                        │
│                                                                 │
│  macOS：                                                        │
│  ├─ ClashX                                                    │
│  ├─ ClashX Meta                                              │
│  └─ Surge for Mac                                            │
│                                                                 │
│  Linux：                                                        │
│  ├─ Clash.Meta CLI                                            │
│  └─ 命令行使用                                                 │
│                                                                 │
│  iOS：                                                          │
│  ├─ Shadowrocket (小火箭)                                       │
│  ├─ Quantumult X（圈X）                                        │
│  ├─ Stash                                                     │
│  └─ Loon                                                      │
│                                                                 │
│  Android：                                                      │
│  ├─ Clash for Android (CFA)                                    │
│  ├─ Clash Meta for Android                                     │
│  └─ Magisk 模块                                                │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 Clash for Windows 配置

```
Clash for Windows 配置：

界面组成：
├─ 主面板：代理节点列表
├─ 代理组：规则分组
├─ 连接：实时流量监控
├─ 设置：详细配置
└─ 订阅：订阅管理

基础使用流程：
1. 导入订阅或手动配置
2. 选择代理组
3. 启用系统代理或 TUN 模式
4. 查看连接状态
```

---

## 8. 与 Surge 的关系

### 8.1 Surge 功能

**Surge** 是 iOS/macOS 上的高级网络工具，与 Clash 有很多相似功能：

```
Surge vs Clash：

┌─────────────────────────────────────────────────────────────────┐
│                      功能对比                                    │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  Surge 独有功能：                                                │
│  ├─ iOS 系统级代理                                              │
│  ├─ VPN Configuration API                                       │
│  ├─ Wi-Fi 辅助                                                  │
│  ├─ MITM 调试                                                  │
│  └─ 更好的 UI/UX                                               │
│                                                                 │
│  Clash 优势：                                                    │
│  ├─ 开源免费                                                    │
│  ├─ 多平台支持                                                  │
│  ├─ 更活跃的社区                                                │
│  └─ 更丰富的规则生态                                            │
│                                                                 │
│  配置兼容：                                                      │
│  ├─ Surge 配置格式与 Clash 相似                                  │
│  ├─ 部分规则可以共用                                            │
│  └─ 订阅转换服务支持两种格式                                     │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### 8.2 配置格式对比

```
Surge 格式 vs Clash 格式：

Surge (Surge.conf)：
[Proxy]
🇭🇰 香港 = ss, 1.2.3.4, 8388, encrypt-method=aes-128-gcm, password=xxx

[Proxy Group]
Auto = url-test, 🇭🇰 香港, 🇯🇵 日本, interval=300

[Rule]
DOMAIN-SUFFIX,cn,DIRECT
GEOIP,CN,DIRECT
DOMAIN-KEYWORD,google,Auto
FINAL,Auto

Clash (config.yaml)：
proxies:
  - name: 🇭🇰 香港
    type: ss
    server: 1.2.3.4
    port: 8388
    cipher: aes-128-gcm
    password: xxx

proxy-groups:
  - name: Auto
    type: url-test
    proxies:
      - 🇭🇰 香港
      - 🇯🇵 日本
    url: "http://www.gstatic.com/generate_204"
    interval: 300

rules:
  - DOMAIN-SUFFIX,cn,DIRECT
  - GEOIP,CN,DIRECT
  - DOMAIN-KEYWORD,google,Auto
  - MATCH,Auto
```

---

## 9. 总结

```
Clash 核心要点：

┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  项目定位：                                                      │
│  ├─ 代理客户端和规则分流引擎                                     │
│  ├─ 不实现代理协议（依赖后端）                                    │
│  └─ 强大的规则管理和分流能力                                      │
│                                                                 │
│  版本选择：                                                      │
│  ├─ 推荐 Clash.Meta / Mihomo（开源活跃）                         │
│  ├─ 有预算可选 Clash Premium                                     │
│  └─ 不推荐使用原版 Clash                                        │
│                                                                 │
│  核心功能：                                                      │
│  ├─ 多协议支持（SS/VMess/VLESS/Trojan）                        │
│  ├─ 规则分流（DOMAIN/IP/GEOIP/RULE-SET）                       │
│  ├─ 订阅管理（自动更新节点和规则）                                │
│  ├─ TUN 模式（全局代理）                                        │
│  └─ DNS 劫持（防污染）                                          │
│                                                                 │
│  最佳实践：                                                      │
│  ├─ 服务端使用 Xray/V2Ray/Trojan                               │
│  ├─ 客户端使用 Clash.Meta                                       │
│  ├─ 合理配置规则减少代理流量                                      │
│  └─ 使用订阅转换服务简化管理                                      │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Clash 是翻墙生态中不可或缺的客户端工具，其强大的规则系统和订阅管理能力使得复杂的多节点、多策略配置变得简单易管理。配合优秀的后端代理服务，Clash 可以构建一个高效、稳定、难检测的翻墙系统。

---

## 参考资料

1. Clash. "Clash." GitHub Repository.
2. ClashMeta. "Clash.Meta." GitHub Repository.
3. Dreamater. "Clash for Windows." Official Website.
4. MetaCube. "Mihomo." GitHub Repository.
