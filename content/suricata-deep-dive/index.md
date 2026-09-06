---
title: "Suricata 深度探索系列索引"
date: 2026-04-15
pin: true
description: "Suricata IDS/IPS 深度探索系列——每个配置项均对应源码解析，从配置加载、线程模型、包捕获、检测引擎、协议解析、日志输出，到规则编写、性能调优，40+ 章节系统性解析 Suricata 配置与源码的映射关系"
tags:
  - suricata
  - series
  - ids
  - ips
  - nids
  - nsm
  - detection
---

# Suricata 深度探索系列

> [!tip] 系列说明
> 本系列约 40+ 篇文章，**每个配置项均对应源码解析**。不同于传统文档或配置手册，本系列从 Suricata 源码（Rust/C 混合）出发，讲解配置如何被解析、线程模型如何运作、检测引擎如何匹配、包捕获如何优化、协议解析如何扩展、日志如何输出。
>
> 配套 [[dpdk-deep-dive|DPDK 系列]]（高性能数据包处理）和 [[srv6-deep-dive|SRv6 系列]]（网络编程），构成完整的"网络安全与高性能网络"知识体系。

---

## Part I：基础入门 (Getting Started)

| #   | 章节               | 主题                | 状态                                                   |
| --- | ------------------ | ------------------- | ------------------------------------------------------ | --- |
| 1   | [[ch1-overview     | Suricata 概述]]     | 项目历史、架构概览、NIDS vs IPS vs NSM                 | ✅  |
| 2   | [[ch2-config       | Suricata 配置系统]] | YAML 配置解析、SCConf、配置树、命令行参数              | ✅  |
| 3   | [[ch3-runmodes     | Runmodes]]          | PCAP/UnixSocket/Auto/Worker/NFQ 运行模式               | ✅  |
| 4   | [[ch4-thread-model | 线程模型]]          | 线程池、TM 模块、Stream-Tagged Architecture            | ✅  |
| 5   | [[ch5-capture      | Capture 初始化]]    | 配置字段 → 源码解析（max-pending-packets/buffer-size） | ✅  |

---

## Part II：包捕获 (Packet Capture)

|| # | 章节 | 主题 | 状态 |
||---|------|------|------|
|| 6 | [[ch6-af-packet|AF-PACKET]] | af-packet 配置 → TPS 线程源码解析 | ✅ |
|| 7 | [[ch7-pcap|PCAP]] | pcap 配置 → 抓包实现源码 | ✅ |
|| 8 | [[ch8-nfq|NFQ]] | NFQ 模式配置 → iptables 集成源码 | ✅ |
|| 9 | [[ch9-dpdk|DPDK]] | dpdk 配置 → DPDK 接口源码解析 | ✅ |
|| 10 | [[ch10-loadbalancing|多线程抓包与负载均衡]] | Worker/AutoFP 模式 → Flow 均衡源码 | ✅ |

---

## Part III：检测引擎 (Detection Engine)

|| # | 章节 | 主题 | 状态 |
||---|------|------|------|
|| 11 | [[ch11-detect-engine|检测引擎架构]] | Detect 工作流程、SigGroupBuild、匹配流水线 | ✅ |
|| 12 | [[ch12-signatures|规则解析]] | Signature 解析流程（YAML/lua/c-headers → 内部结构体） | ✅ |
|| 13 | [[ch13-mpm|多模式匹配]] | MPM（AC/Bm/Hyperscan）算法与配置 | ✅ |
|| 14 | [[ch14-filemagic|文件识别]] | file-data 配置 → magic 匹配源码 | ✅ |
|| 15 | [[ch15-lua-detect|Lua 检测]] | lua 规则配置 → LuaJIT 集成源码 | ✅ |

---

## Part IV：协议解析 (App-layer Parsers)

| #   | 章节             | 主题         | 状态                                |
| --- | ---------------- | ------------ | ----------------------------------- | --- |
| 16  | [[ch16-app-layer | 应用层解析]] | AppLayer 框架、注册流程、状态机     | 🚧  |
| 17  | [[ch17-http      | HTTP 解析]]  | http 配置 → HTP 库解析源码          | 🚧  |
| 18  | [[ch18-dns       | DNS 解析]]   | dns 配置 → DNS 状态机与查询日志源码 | 🚧  |
| 19  | [[ch19-tls       | TLS 解析]]   | tls 配置 → 证书解析、SNI 日志源码   | 🚧  |
| 20  | [[ch20-smb       | SMB 解析]]   | smb 配置 → SMB2/3 协议检测源码      | 🚧  |
| 21  | [[ch21-http2     | HTTP/2]]     | http2 配置 → h2 协议解析源码        | 🚧  |

---

## Part V：Flow 处理 (Flow Engine)

|| # | 章节 | 主题 | 状态 |
||---|------|------|------|
|| 22 | [[ch22-flow|Flow 管理]] | flow 配置 → Flow 哈希表、生命周期源码 | ✅ |
|| 23 | [[ch23-flow-timeout|Flow 超时]] | flow-timeout 配置 → 超时状态机源码 | ✅ |
|| 24 | [[ch24-flowbit|Flowbit]] | flowbit 配置 → FlowBit/FlowInt/Flowvar 源码 | ✅ |
|| 25 | [[ch25-host|Host 管理]] | host 配置 → Host 哈希表、源码 | ✅ |

---

## Part VI：Stream 重组 (Stream Reassembly)

| #   | 章节                 | 主题          | 状态                                                   |
| --- | -------------------- | ------------- | ------------------------------------------------------ | --- |
| 26  | [[ch26-stream        | Stream 重组]] | stream 配置 → Stream-TCP 重组引擎源码                  | 🚧  |
| 27  | [[ch27-stream-policy | 重组策略]]    | stream.reassembly 配置 → 重组策略（BSD/Linux/Windows） | 🚧  |
| 28  | [[ch28-stream-depth  | 深度配置]]    | stream.depth/stream.reassembly.depth 配置 → 源码       | 🚧  |

---

## Part VII：输出系统 (Outputs)

| #   | 章节            | 主题       | 状态                                    |
| --- | --------------- | ---------- | --------------------------------------- | --- |
| 29  | [[ch29-eve      | EVE JSON]] | eve 配置 → JSON 输出插件、字段映射源码  | 🚧  |
| 30  | [[ch30-alerts   | Alerts]]   | alert 配置 → Alert 产生与输出源码       | 🚧  |
| 31  | [[ch31-stats    | Stats]]    | stats 配置 → 统计输出、计数器源码       | 🚧  |
| 32  | [[ch32-file-log | File Log]] | filedata 配置 → 文件日志、MD5/SHA1 提取 | 🚧  |
| 33  | [[ch33-unified2 | Unified2]] | unified2 配置 → Barnyard2 集成源码      | 🚧  |

---

## Part VIII：规则编写 (Rule Writing)

| #   | 章节             | 主题        | 状态                               |
| --- | ---------------- | ----------- | ---------------------------------- | --- |
| 34  | [[ch34-rules     | 规则语法]]  | 规则结构 → 语法解析器源码          | 🚧  |
| 35  | [[ch35-http-sids | HTTP 规则]] | http.\* 关键字配置与检测逻辑源码   | 🚧  |
| 36  | [[ch36-dns-sids  | DNS 规则]]  | dns.query 关键字配置与检测逻辑源码 | 🚧  |
| 37  | [[ch37-tls-sids  | TLS 规则]]  | tls.\* 关键字配置与检测逻辑源码    | 🚧  |

---

## Part IX：性能调优 (Performance)

| #   | 章节             | 主题        | 状态                                      |
| --- | ---------------- | ----------- | ----------------------------------------- | --- |
| 38  | [[ch38-counters  | 计数配置]]  | stats 配置 → perf 计数器、TmModule 统计   | 🚧  |
| 39  | [[ch39-memory    | Memory]]    | memory 配置 → 全局内存池、分配策略源码    | 🚧  |
| 40  | [[ch40-hyperscan | Hyperscan]] | mpm.hyperscan 配置 → Intel Hyperscan 集成 | 🚧  |

---

## Part X：高级话题 (Advanced)

|     | #                         | 章节            | 主题                                     | 状态 |
| --- | ------------------------- | --------------- | ---------------------------------------- | ---- |
| 41  | [[ch41-iprep              | IP 信誉]]       | reputation 配置 → IP 信誉数据库加载源码  | ✅   |
| 42  | [[ch42-dataset            | Dataset]]       | dataset 配置 → Dataset/Lua 动态列表源码  | ✅   |
| 43  | [[ch43-app-layer-register | 自定义 Parser]] | AppLayer Register → 自定义协议解析器开发 | ✅   |
| 44  | [[ch44-rust               | Rust 扩展]]     | Rust 插件系统 → Suricata-Rust 扩展开发   | ✅   |
| 45  | [[ch45-cluster            | 集群模式]]      | unix-cluster 配置 → 分布式 Suricata 集群 | ✅   |

---

## 相关系列

- [[dpdk-deep-dive|DPDK 深度探索系列]] — 高性能数据包处理
- [[p4-deep-dive|P4 深度探索系列]] — 可编程数据面
- [[srv6-deep-dive|SRv6 深度探索系列]] — 网络编程
- [[cilium-deep-dive|Cilium 深度探索系列]] — eBPF 云原生网络
