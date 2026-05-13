---
title: sniffnet 网络流量监控工具调研
date: 2026-04-24 10:00:00
tags: [network, github, rust, tooling, traffic-monitoring]
description: Rust 编写的跨平台网络流量监控工具，支持 pcap 抓包、协议分析和可视化展示
---

# sniffnet 网络流量监控工具调研

## 项目概览

**sniffnet** 是一个用 Rust 编写的跨平台网络流量监控工具，提供直观的 GUI 界面，让用户能够舒适地监控和分析互联网流量。

| 指标         | 数值                    |
| ------------ | ----------------------- |
| GitHub Stars | 35.7k                   |
| Forks        | 1.4k                    |
| Commits      | 2,864                   |
| 主要语言     | Rust                    |
| 最新更新     | 2026-04-23（15 小时前） |
| 支持平台     | Windows, macOS, Linux   |

项目定位为**个人网络流量分析器**，适合开发者、安全研究人员和普通用户监控本机网络活动。

## 核心技术亮点

### 1. 跨平台 pcap 抓包

sniffnet 基于 `pcap` 库实现网络数据包捕获，支持：

- **Windows**: Npcap / WinPcap
- **Linux**: libpcap
- **macOS**: BPF

底层使用 Rust 的异步运行时 `tokio` 处理高并发数据包，支持千兆网络环境下的实时抓包分析。

### 2. 协议深度解析

支持多种网络协议的自动识别和统计：

- **L4 协议**: TCP, UDP, ICMP
- **L7 应用层**: HTTP, HTTPS, DNS, SSH, MQTT 等
- **TLS 指纹**: 支持 JA3/JA4 TLS 客户端指纹识别

### 3. 实时可视化流量统计

提供现代化的 GUI 界面（基于 `iced` 库），实时展示：

- **流量趋势图**: 按时间轴显示字节数/数据包数
- **Top 10 流量**: 最高流量应用/域名/端口排名
- **协议分布饼图**: 各类协议流量占比
- **地理流量地图**: 基于 IP 地理位置的可视化

### 4. 流量过滤与聚合

支持 BPF 过滤器语法，可按以下维度过滤：

- 源/目标 IP 地址
- 源/目标端口
- 协议类型
- AS 编号

## 适用场景

| 场景     | 用途                            |
| -------- | ------------------------------- |
| 开发调试 | 分析应用网络请求，调试 API 调用 |
| 安全分析 | 检测异常流量，识别后门通信      |
| 性能优化 | 定位带宽占用大户                |
| 隐私监控 | 审计未知应用的网络行为          |

## 最新更新 (2026-04)

近期更新内容：

- 更新 Rust 1.95 版本的 clippy lints 兼容
- GitHub Actions 工作流升级至 actions/checkout@v6
- 更新依赖版本（`update deps`）
- 路线图截图更新

## 安装使用

### macOS (Homebrew)

```bash
brew install sniffnet
```

### Linux

```bash
# 需要安装 libpcap-dev
sudo apt install libpcap-dev
# 下载 Release 包或编译安装
```

### Windows

下载 Windows 安装包，需要先安装 Npcap 驱动。

### 基本使用

```bash
# 启动 GUI
sniffnet

# 指定网卡抓包
sniffnet --interface eth0

# 应用 BPF 过滤器
sniffnet --filter "tcp port 80"
```

## 技术栈分析

```
┌─────────────────────────────────────┐
│            iced (GUI)               │
├─────────────────────────────────────┤
│         tokio (异步 runtime)         │
├─────────────────────────────────────┤
│  pcap    │  tls_parser  │  ipinfo  │
│ (抓包)   │  (TLS解析)   │  (GeoIP) │
└─────────────────────────────────────┘
```

- **iced**: 纯 Rust 跨平台 GUI 库，声明式 UI
- **tokio**: 生产级异步运行时，支持高并发
- **pcap**: 标准数据包捕获接口
- **tls_parser**: 纯 Rust TLS 协议解析

## 总结

sniffnet 是一个活跃开发的网络监控工具，Rust 实现保证了高性能和内存安全。其跨平台特性和现代化 UI 使其成为个人网络流量分析的理想选择。相比 tcpdump/ wireshark，sniffnet 更注重流量统计和可视化，适合日常监控场景。
