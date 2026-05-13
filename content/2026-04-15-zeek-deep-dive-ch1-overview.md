---
title: "Zeek 深度探索 (一)：Zeek 概述"
date: 2026-04-15
tags:
  - zeek
  - series
  - ids
  - nsm
  - bro
  - network-analysis
description: "Zeek（原 Bro）网络分析框架概述——项目历史、架构概览、与 Suricata 对比、源码目录结构解读"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. **第一章：Zeek 概述**
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]

---

## 1. 项目历史与定位

### 1.1 从 Bro 到 Zeek

Zeek 起源于 **Berkeley Lab**（劳伦斯伯克利国家实验室），由 **Vern Paxson** 于 1995 年开发，初名 **Bro**，是一个专门用于网络协议分析的研究项目。2000 年代初，项目由 **Robin Sommer** 和 **Seth Hall** 继续推进，逐渐从研究工具演变为生产级网络分析框架。

```
关键里程碑：
1995  — Vern Paxson 在 LBNL 开始 Bro 项目
1996  — 首个公开版本 Bro 0.3
2005  — Bro 2.0 引入全新事件引擎架构
2010  — Bro 2.1，脚本策略框架成熟
2013  — National Cyber Security Alliance 商业化尝试
2018  — Bro 项目正式更名为 Zeek（避免品牌冲突）
2019  — Zeek 3.0，现代化工程启动
2022  — Zeek 5.0，Broker 通信框架稳定
2024  — Zeek 7.0，AF_XDP 支持、现代 C++ 重构
```

**2018 年品牌更名**：Bro 名称与某安全公司品牌产生冲突，项目团队决定更名。Zeek 这个名字既保留了"B"的发音延续性（Zee-Bro），又是一个全新的品牌。**代码层面**的更名包括：
- `bro` → `zeek`（命令行、目录名）
- `bro-cut` → `zeek-cut`
- `bro-http` → `zeek-http`
- **ZeekScript** 保留原名
- 配置文件后缀 `.bro` → `.zeek`

### 1.2 定位：脚本驱动的 NSM 框架

Zeek 定位为 **NSM（Network Security Monitoring）** 框架，而非单纯的 IDS。与 Suricata 的规则驱动（Signature-based）不同，Zeek 采用 **脚本驱动（Script-driven）** 的分析范式：

| 维度 | Zeek | Suricata |
| :--- | :--- | :--- |
| **分析范式** | 脚本驱动（Policy-by-script） | 规则驱动（Rule-based） |
| **核心语言** | ZeekScript（事件型脚本） | Suricata Rules（模式匹配） |
| **日志粒度** | 细粒度连接记录 + 应用层语义 | 告警 + 流记录 |
| **协议分析** | 内置协议解析器（HTTP/DNS/TLS/...） | 协议检测 + 规则匹配 |
| **定制方式** | ZeekScript 脚本 + C++ 插件 | 规则编写 + Lua 脚本 |
| **性能模型** | 事件引擎（单线程 + 多 worker） | 多线程流水线 |

Zeek 的核心哲学：**"记录一切，分析在后"** — Zeek 尽可能完整地记录网络行为，生成高价值的结构化日志，分析师在事后通过日志进行深度调查。

### 1.3 开源生态

Zeek 采用 **BSD License**，代码托管于 [GitHub/zeek](https://github.com/zeek/zeek)。项目由 **Zeek Project** 社区维护，核心贡献者包括：

- Vern Paxson（创始人，Corelight CTO）
- Robin Sommer（Los Alamos National Lab）
- Seth Hall（et al.）

商业发行版 **Corelight** 提供企业级 Zeek 解决方案，包括增强的协议解析器、商业支持和可视化平台。

---

## 2. 架构概览

### 2.1 整体架构

Zeek 架构分为 **C++ 核心层** 和 **ZeekScript 脚本层** 两大组成部分：

```
┌─────────────────────────────────────────────────────────┐
│                    ZeekScript 脚本层                     │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────────┐  │
│  │  Event      │  │  Handler     │  │  Policy       │  │
│  │  Handlers   │  │  Scripts     │  │  Scripts      │  │
│  └─────────────┘  └──────────────┘  └───────────────┘  │
│                          ↑                              │
│                    事件 + 日志回调                        │
├──────────────────────────┼─────────────────────────────┤
│                    C++ 核心层                            │
│  ┌─────────────┐  ┌──────┴──────┐  ┌───────────────┐  │
│  │  Packet     │  │  Event      │  │  Analyzer     │  │
│  │  Manager    │→ │  Engine     │→ │  Framework    │  │
│  └─────────────┘  └─────────────┘  └───────────────┘  │
│         ↑                                           ↑  │
│  ┌──────┴──────────────────────────────────────┐   │  │
│  │           Network Interface (libpcap)       │   │  │
│  └─────────────────────────────────────────────┘   │  │
└─────────────────────────────────────────────────────┘
```

**核心组件**：

1. **Packet Manager**：从网络接口抓取数据包，通过 `libpcap` / `AF_XDP` / `PF_RING` 等接口
2. **Event Engine**：将数据包转化为事件（_events），是 Zeek 的心脏
3. **Script Interpreter**：执行 ZeekScript 脚本，处理事件
4. **Analyzer Framework**：协议解析器框架，支持 HTTP、DNS、TLS、SMB 等协议
5. **Logging Framework**：将分析结果写入日志文件

### 2.2 事件驱动模型

Zeek 的核心是 **事件驱动（Event-driven）** 模型。数据包到达后：

```
数据包 → Event Engine（分用）→ 事件序列 → Script Interpreter → Event Handlers
```

例如，一个完整的 HTTP 请求会触发以下事件序列：

```
packet → tcp_packet → new_connection → connection_first_packet
  → protocol_confirmation → http_request → http_header
  → http_request_line → http_entity_data → http_message_done
  → connection_state_remove
```

每个事件都有对应的 **ZeekScript 事件处理程序**，用户通过编写 `when` 事件处理程序来定制分析逻辑。

### 2.3 Zeek 的"分析日志优先"哲学

Zeek 输出的日志不仅是告警，而是 **完整的高价值结构化数据**。每个网络连接、每个 HTTP 请求、每个 DNS 查询都被完整记录：

```
# conn.log — 每个 TCP/UDP 连接一条记录
uid          id.resp_h    id.resp_p   duration    orig_bytes  resp_bytes
ChhnUs4ev... 192.168.1.1  443         12.345      1234        5678

# http.log — 每个 HTTP 请求一条记录
ts           host        uri         method      status_code  user_agent
2026-04-15   example.com /api/v1     GET         200          curl/7.68.0
```

这些日志可用于：
- **威胁狩猎**：通过日志关联发现攻击痕迹
- **网络取证**：还原完整的网络会话
- **性能分析**：分析连接延迟、流量模式
- **合规审计**：记录网络活动满足合规要求

---

## 3. 与 Suricata 对比

### 3.1 核心设计差异

Zeek 和 Suricata 都是网络分析框架，但设计哲学截然不同：

| 特性 | Zeek | Suricata |
| :--- | :--- | :--- |
| **分析方式** | 脚本驱动，语义分析 | 规则驱动，模式匹配 |
| **日志类型** | 连接 + 应用层详细日志 | 告警（Alert）+ 流统计 |
| **协议理解** | 完整协议状态机 | 协议检测 + 规则匹配 |
| **误报率** | 低（语义分析更精准） | 依赖规则质量 |
| **吞吐量** | ~1-5 Gbps（单 worker） | ~10+ Gbps（多线程流水线） |
| **学习曲线** | 高（需要学 ZeekScript） | 中（规则语法简单） |
| **定制能力** | 极强（脚本 + C++ 插件） | 强（规则 + Lua） |

### 3.2 互补部署场景

**最佳实践**：Zeek + Suricata 联合部署：

```
                    Network Traffic
                          │
            ┌─────────────┼─────────────┐
            ↓             ↓             ↓
        Switch      Zeek (IDS)      Suricata (IDS)
        SPAN Port   Passive         Passive
            │             │             │
            ↓             ↓             ↓
        ┌───────────────────────────────┐
        │    SIEM / SOAR Platform      │
        │  (Splunk / Elastic / Chronicle)│
        └───────────────────────────────┘
```

- **Zeek**：生成详细日志用于威胁狩猎和取证
- **Suricata**：规则匹配实时检测已知攻击
- **联合分析**：Suricata 告警 + Zeek 日志关联分析

### 3.3 日志对比示例

同一个 HTTP 请求在两个系统中的输出：

**Suricata EVE JSON（告警导向）**：
```json
{
  "event_type": "http",
  "src_ip": "192.168.1.100",
  "dest_ip": "93.184.216.34",
  "http": {
    "hostname": "example.com",
    "uri": "/api/v1/users",
    "method": "GET",
    "status": 200
  }
}
```

**Zeek http.log（完整记录）**：
```json
{
  "ts": 1713206400.123,
  "uid": "ChhnUs4ev9k2",
  "id.orig_h": "192.168.1.100",
  "id.resp_h": "93.184.216.34",
  "id.resp_p": 443,
  "trans_depth": 1,
  "host": "example.com",
  "uri": "/api/v1/users",
  "method": "GET",
  "status_code": 200,
  "status_msg": "OK",
  "user_agent": "curl/7.68.0",
  "orig_bytes": 0,
  "resp_bytes": 1234,
  "missed_bytes": 0,
  "protocol": "HTTP/1.1",
  "request_body_len": 0,
  "response_body_len": 1234,
  "content_type": "application/json"
}
```

Zeek 日志包含更丰富的字段（uid 连接追踪、请求/响应字节数、请求体长度、响应体长度、协议版本等），更适合深度分析。

---

## 4. 源码目录结构

### 4.1 顶级目录

Zeek 源码采用清晰的分层结构：

```
zeek/
├── src/                 # C++ 核心实现
├── scripts/             # ZeekScript 脚本（内置策略）
├── testing/             # 测试框架（BTest）
├── auxiliary/           # 辅助工具、协议测试
├── CMakeLists.txt       # CMake 构建配置
└── INSTALL             # 安装指南
```

### 4.2 src/ 核心目录

```
src/
├── main.cc              # 程序入口
├── Event.cc/.h         # 事件引擎核心
├── EventHandler.cc/.h  # 事件处理程序
├── NetVar.cc/.h        # 全局网络变量
├── Conn.cc/.h          # 连接对象（connection）
├── RecordType.cc/.h    # ZeekScript record 类型
├── Val.cc/.h           # ZeekScript 值对象
├── BROConfig.h         # 配置宏（版本、路径）
├── (protocol analyzers)/
│   ├── HTTP.cc/.h      # HTTP 分析器
│   ├── DNS.cc/.h       # DNS 分析器
│   ├── TLS.cc/.h       # TLS 分析器
│   └── SMB.cc/.h       # SMB 分析器
├── (log writers)/
│   ├── ASCII.cc/.h     # ASCII 日志写入器
│   ├── JSON.cc/.h      # JSON 日志写入器
│   └── ...
└── (utilities)/
    ├── Debug.cc/.h      # 调试工具
    ├── Reporter.cc/.h  # 错误/警告报告
    └── fm.def          # 文件修改映射（哈希）
```

### 4.3 scripts/ 内置脚本

```
scripts/
├── base/               # 基础脚本（always loaded）
│   ├── init-bare.zeek      # 最简初始化
│   ├── init.zeek           # 标准初始化
│   ├── frame/              # 框架脚本（协议分析）
│   │   ├── http.zeek
│   │   ├── dns.zeek
│   │   ├── tls.zeek
│   │   └── notice.zeek
│   └── policy/             # 策略脚本（可选加载）
│       ├── misc/           # 扫描检测等
│       ├── protocols/      # 协议相关策略
│       └── tuning/
├── zeekctl/            # zeekctl 控制脚本
└── site/               # 本地站点脚本
```

---

## 5. 快速入门

### 5.1 安装 Zeek

```bash
# Ubuntu/Debian
sudo apt install zeek

# 或者从源码编译（见第二章）
# macOS
brew install zeek
```

### 5.2 启动 Zeek

```bash
# 抓取接口流量（单节点）
zeek -i eth0

# 使用 zeekctl 管理（推荐）
zeekctl
> deploy
> status

# 后台运行
zeekctl deploy
```

### 5.3 查看日志

```bash
# 默认日志输出目录
ls /usr/local/zeek/logs/current/

# conn.log (连接记录)
zeek-cut ts id.orig_h id.resp_h id.resp_p proto service < conn.log

# http.log (HTTP 请求)
zeek-cut ts host uri method status_code < http.log
```

### 5.4 zeekctl 交互

```bash
$ zeekctl

Zeek Control System 7.x.x
Type "help" for a list of commands.

[ZeekControl]> status
Name         Type    Host       Status    Pid    Peers  Started
zeek        local   localhost   running   12345     0   Apr 15 10:00

[ZeekControl]> diag
# 查看 zeek 进程诊断信息
```

---

## 6. 本章小结

本章介绍了 Zeek 网络分析框架的基本概念：

1. **项目历史**：从 1995 年 Bro 项目到 2018 年更名为 Zeek，20+ 年发展历程
2. **核心定位**：脚本驱动的 NSM 框架，强调"完整记录 + 事后分析"
3. **架构特点**：事件驱动模型，C++ 核心 + ZeekScript 策略层
4. **与 Suricata 对比**：Zeek 擅长语义分析和高价值日志，Suricata 擅长实时规则检测
5. **源码结构**：清晰的 C++ 核心 / scripts 策略分层

**下一章**将详细介绍 Zeek 的安装部署，包括源码编译、依赖库和版本选择。
