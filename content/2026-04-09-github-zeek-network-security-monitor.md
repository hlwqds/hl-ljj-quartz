---
title: Zeek - 强大的网络流量分析与安全监控框架
date: 2026-04-09 10:30:00
tags: [zeek, network-security, ids, traffic-analysis, monitoring]
description: Zeek 是一个功能强大的网络流量分析和安全监控框架，与传统 IDS 完全不同
---

# Zeek - 强大的网络流量分析与安全监控框架

## 项目概览

| 属性 | 值 |
|------|-----|
| **GitHub** | [zeek/zeek](https://github.com/zeek/zeek) |
| **Stars** | 7.6k |
| **语言** | C++ / Zeek Script |
| **最新更新** | 39 分钟前 (2026-04-09) |
| **最新版本** | v6.x |
| **License** | BSD |
| **分支数** | 412 |

## 核心定位

Zeek 是一个**功能强大的网络流量分析框架**，与传统 IDS（入侵检测系统）有本质区别。它不是简单的模式匹配工具，而是一个**可编程的分析平台**。

### 官方定义

> Zeek is a powerful framework for network traffic analysis and security monitoring.

## 与传统 IDS 的区别

| 维度 | 传统 IDS (如 Snort) | Zeek |
|------|---------------------|------|
| **分析方法** | 签名匹配 | 语义分析 + 行为分析 |
| **协议支持** | 有限 | 深度多协议支持 |
| **脚本能力** | 规则语言 | 完整的脚本语言 |
| **状态维护** | 无/有限 | 完整会话状态 |
| **输出** | 告警 | 结构化日志 |

## 核心特性

### 1. In-depth Analysis (深度分析)

Zeek 内置了大量协议的**应用层语义分析器**：

- HTTP：请求/响应、URI、User-Agent、状态码
- DNS：查询/响应、域名、TTL
- SMTP/IMAP/POP3：邮件内容、附件
- SSH：会话详情
- SSL/TLS：证书信息、加密套件
- SMB、DNP3、Modbus、等等

### 2. Adaptable and Flexible (适应性强)

Zeek 的**领域特定脚本语言**使得：

- 可以编写站点特定的监控策略
- 不局限于任何特定检测方法
- 逻辑可复用、可测试

```zeek
# 示例：检测异常 HTTP 流量
event http_request(c: connection, method: string, original_uri: string, version: string) {
    if ( /\/admin/ in original_uri ) {
        print fmt("Admin access to %s from %s", original_uri, c$id$orig_h);
    }
}
```

### 3. Efficient (高效)

- 面向高性能网络设计
- 在多个大型站点有生产环境使用经验
- 支持集群部署横向扩展

### 4. Highly Stateful (强状态)

Zeek 维护详尽的**应用层状态**：

- 完整的 HTTP 会话记录
- DNS 查询历史
- TLS 握手详情
- 连接统计信息

## 架构组成

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek Script Layer                        │
│              (策略脚本 + 事件处理)                           │
├─────────────────────────────────────────────────────────────┤
│                    Event Engine                             │
│              (事件驱动处理引擎)                              │
├─────────────────────────────────────────────────────────────┤
│                    Packet Processing                        │
│              (数据包处理 + 协议解析)                         │
├─────────────────────────────────────────────────────────────┤
│                    libpcap / AF_PKT                         │
└─────────────────────────────────────────────────────────────┘
```

## 输出类型

Zeek 生成多种结构化日志：

| 日志类型 | 内容 |
|---------|------|
| `conn.log` | 连接记录（TCP/UDP） |
| `http.log` | HTTP 请求/响应 |
| `dns.log` | DNS 查询/响应 |
| `ssl.log` | TLS/SSL 握手信息 |
| `ssh.log` | SSH 会话 |
| `notice.log` | 告警信息 |
| `weird.log` | 异常流量 |

## 使用场景

### 1. 安全运营中心 (SOC)

```bash
# 基础流量监控
zeek -i eth0

# 读取 pcap 文件分析
zeek -r capture.pcap
```

### 2. 威胁狩猎

```zeek
# 检测可疑 DNS 隧道
event dns_reply(c: connection, msg: dns_msg, query: string) {
    if ( |msg$answers| > 10 ) {
        print fmt("Large DNS response: %s -> %d answers", query, |msg$answers|);
    }
}
```

### 3. 网络取证

- 完整记录网络活动
- 追溯安全事件
- 生成取证报告

### 4. 合规审计

- 记录所有网络通信
- 满足 HIPAA、PCI-DSS 等合规要求

## 与 Suricata 对比

| 维度 | Suricata | Zeek |
|------|----------|------|
| **架构** | IDS/IPS 引擎 | 分析框架 |
| **脚本能力** | 规则语言 | 完整脚本语言 |
| **实时性** | 实时检测 | 实时 + 离线分析 |
| **状态** | 会话状态 | 完整应用状态 |
| **输出** | 告警 | 结构化日志 |
| **性能** | 高性能 | 中等（但可集群）|
| **适用** | 实时检测 | 分析+检测 |

**互补使用**：Suricata 负责实时告警，Zeek 负责深度分析。

## 快速开始

### 安装

```bash
# 从源码编译
git clone --recursive https://github.com/zeek/zeek.git
cd zeek
./configure && make -j$(nproc)
sudo make install
```

### 基本使用

```bash
# 监听网络接口
sudo zeek -i eth0

# 分析 pcap 文件
zeek -r suspicious.pcap

# 使用自定义脚本
zeek -r capture.pcap my-script.zeek
```

### 在线学习

访问 [try.zeek.org](https://try.zeek.org) 在线体验 Zeek 脚本。

## 生态组件

- **ZeekControl**：管理和控制框架
- **BroCoin**：Zeek 的加密货币分析插件
- **ZeekAgent**：主机端采集代理
- **Spicy**：协议格式化解析器生成器

---

**相关项目**：
- [Suricata](https://github.com/OISF/suricata) - 6.1k stars，网络 IDS/IPS 和安全监控引擎
- [sniffglue](https://github.com/kpcyrd/sniffglue) - Rust 编写的安全多线程数据包嗅探器
