---
title: sniffglue - Rust 编写的安全多线程数据包嗅探器
date: 2026-04-09 10:15:00
tags: [rust, packet-capture, pcap, network, security]
description: 用 Rust 编写的安全多线程数据包嗅探工具，支持 pcap 格式
---

# sniffglue - Rust 编写的安全多线程数据包嗅探器

## 项目概览

| 属性         | 值                                                      |
| ------------ | ------------------------------------------------------- |
| **GitHub**   | [kpcyrd/sniffglue](https://github.com/kpcyrd/sniffglue) |
| **Stars**    | 1.2k                                                    |
| **语言**     | Rust                                                    |
| **最新更新** | 2025-01-24（约2个月前）                                 |
| **License**  | GPL-3.0                                                 |

## 核心定位

sniffglue 是一个用 **Rust** 编写的安全多线程数据包嗅探器，基于 **libpcap** 实现，主打安全性和高性能。

### 设计目标

- **安全性**：使用 Rust 的内存安全特性，避免传统 C 语言网络工具的缓冲区溢出
- **多线程**：利用 Rust 的并发特性，实现高效数据包处理
- **沙箱化**：支持 pledge/unveil 等沙箱机制，限制进程权限

## 技术特点

### 1. 内存安全

传统网络工具（如 tcpdump）用 C 编写，存在潜在的内存安全漏洞。sniffglue 用 Rust 重写，编译时保证内存安全。

### 2. 多线程架构

```rust
// sniffglue 使用 Rust 的并发特性
// 每个网络接口或数据包类型可以并行处理
```

### 3. 沙箱支持

在 OpenBSD 上支持 `pledge()` 系统调用，限制进程可以执行的操作：

```bash
# 启用沙箱模式（需要 OpenBSD）
sniffglue -s em0
```

### 4. 输出格式

- 彩色输出，便于阅读
- 结构化日志格式
- 支持输出到文件

## 使用示例

### 基本抓包

```bash
# 监听指定接口
sniffglue em0

# 读取 pcap 文件
sniffglue -r capture.pcap
```

### 过滤器

```bash
# TCP 流量
sniffglue em0 tcp

# 特定端口
sniffglue em0 port 80
```

### 性能测试

```bash
# 高性能抓包（减少内存复制）
sniffglue em0 -p
```

## 支持的平台

- Linux
- OpenBSD（支持沙箱）
- macOS
- 其他 Unix-like 系统

## 与 tcpdump 对比

| 维度     | tcpdump | sniffglue    |
| -------- | ------- | ------------ |
| 语言     | C       | Rust         |
| 内存安全 | 不安全  | 安全         |
| 多线程   | 有限    | 原生支持     |
| 沙箱     | 不支持  | OpenBSD 支持 |
| 性能     | 高      | 高           |
| 生态     | 成熟    | 较小         |

## 安全考虑

sniffglue 在以下方面比传统工具更安全：

1. **无缓冲区溢出**：Rust 的所有权系统杜绝了这类漏洞
2. **沙箱化**：在 OpenBSD 上可以通过 pledge 限制权限
3. **最小权限**：不需要时可以禁用特权模式

## 适用场景

1. **安全研究**：安全地分析可疑流量
2. **渗透测试**：快速抓取和分析网络流量
3. **开发调试**：调试网络应用（替代 tcpdump）
4. **安全审计**：在安全敏感环境中替代传统工具

## 构建方法

```bash
# 安装 Rust
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# 克隆并构建
git clone https://github.com/kpcyrd/sniffglue.git
cd sniffglue
cargo build --release

# 运行
sudo ./target/release/sniffglue em0
```

## 局限性与注意事项

1. **功能相对简单**：不像 tcpdump 那样功能丰富
2. **生态较小**：插件和扩展有限
3. **需要 root 权限**：监听网络接口通常需要特权

---

**相关项目**：

- [tcpdump](https://github.com/the-tcpdump-group/tcpdump) - 经典网络抓包工具
- [eCapture](https://github.com/gojue/ecapture) - eBPF 无 CA 证书抓取 TLS 明文
