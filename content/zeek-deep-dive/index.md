---
title: "Zeek 深度探索系列索引"
date: 2026-04-15
pin: true
description: "Zeek（原 Bro）网络分析框架深度探索系列——每个配置项对应源码解析，从 Zeek 架构、脚本语言（ZeekScript）、协议分析（HTTP/DNS/TLS/SMB）、日志系统、流量分析、集群部署，到自定义插件开发、性能调优，40+ 章节系统性解析 Zeek 配置与源码的映射关系"
tags:
  - zeek
  - series
  - ids
  - nsm
  - network-analysis
  - bro
  - security
---

# Zeek 深度探索系列

> [!tip] 系列说明
> 本系列约 40+ 篇文章，**每个配置项均对应源码解析**。Zeek 与 Suricata 同为网络分析框架，但 Zeek 以脚本驱动（ZeekScript）为核心，提供更深入的应用层语义分析。本系列从 Zeek 源码（C++ / ZeekScript）出发，讲解配置如何驱动脚本引擎、协议解析器如何构建日志、集群如何协调、插件如何开发。
>
> 配套 [[suricata-deep-dive|Suricata 系列]]（规则驱动 IDS）和 [[dpdk-deep-dive|DPDK 系列]]（高性能数据包处理），构成完整的"网络安全分析"知识体系。

---

## Part I：基础入门 (Getting Started)

| #   | 章节               | 主题        | 状态                                         |
| --- | ------------------ | ----------- | -------------------------------------------- | --- |
| 1   | [[ch1-overview     | Zeek 概述]] | 项目历史、架构概览、与 Suricata 对比         | 🚧  |
| 2   | [[ch2-installation | 安装部署]]  | 源码编译 / 安装、依赖库、版本选择            | 🚧  |
| 3   | [[ch3-config       | 配置系统]]  | zeekctl 配置、node.cfg、zeek_path 脚本加载   | 🚧  |
| 4   | [[ch4-architecture | Zeek 架构]] | C++ 核心引擎、事件引擎、脚本解释器、协议框架 | 🚧  |
| 5   | [[ch5-logging      | 日志系统]]  | ASCII/JSON/CSV 输出、Log Writer、Writer 框架 | 🚧  |

---

## Part II：ZeekScript 语言 (Scripting)

| #   | 章节             | 主题              | 状态                                           |
| --- | ---------------- | ----------------- | ---------------------------------------------- | --- |
| 6   | [[ch6-scriptlang | ZeekScript 基础]] | 类型系统（record/table/set/vector）、内置类型  | 🚧  |
| 7   | [[ch7-events     | 事件]]            | 事件驱动模型、事件队列、事件处理程序           | 🚧  |
| 8   | [[ch8-hooks      | Hooks]]           | Hook 与事件区别、hook 处理程序、条件触发       | 🚧  |
| 9   | [[ch9-packages   | Packages]]        | Zeek Package Manager、@load 加载、脚本组织     | 🚧  |
| 10  | [[ch10-debugging | 调试]]            | zeek -b 调试、printf/dump荤志、script coverage | 🚧  |

---

## Part III：协议分析 (Protocol Analysis)

| #   | 章节         | 主题         | 状态                                          |
| --- | ------------ | ------------ | --------------------------------------------- | --- |
| 11  | [[ch11-http  | HTTP 分析]]  | HTTP 分析器、HTTP::Info record、请求/响应日志 | ✅  |
| 12  | [[ch12-dns   | DNS 分析]]   | DNS 分析器、DNS::Info、查询/响应日志          | ✅  |
| 13  | [[ch13-tls   | TLS 分析]]   | TLS 分析器、Certificate info、SNI/JA3/JARM    | ✅  |
| 14  | [[ch14-smb   | SMB 分析]]   | SMB 分析器、SMB::Info、文件传输日志           | ✅  |
| 15  | [[ch15-ssh   | SSH 分析]]   | SSH 分析器、SSH::Info、暴力破解检测           | ✅  |
| 16  | [[ch16-ftp   | FTP 分析]]   | FTP 分析器、FTP::Info、文件获取日志           | ✅  |
| 17  | [[ch17-smtp  | SMTP 分析]]  | SMTP 分析器、邮件附件提取、邮件日志           | ✅  |
| 18  | [[ch18-rdp   | RDP 分析]]   | RDP 分析器、RDP::Info、屏幕截图日志           | ✅  |
| 19  | [[ch19-kafka | Kafka 分析]] | Kafka 分析器、Kafka Writer 配置               | ✅  |

---

## Part IV：流量分析 (Traffic Analysis)

| #   | 章节              | 主题          | 状态                                   |
| --- | ----------------- | ------------- | -------------------------------------- | --- |
| 20  | [[ch20-conn       | 连接分析]]    | connection.log、Conn::Info、连接状态机 | ✅  |
| 21  | [[ch21-weirds     | Weird 日志]]  | Weird 事件、非正常流量、异常检测       | ✅  |
| 22  | [[ch22-files      | 文件分析]]    | 文件提取、file-analysis 框架、哈希计算 | ✅  |
| 23  | [[ch23-signatures | 签名检测]]    | Sig::Info、签名匹配、协议检测          | ✅  |
| 24  | [[ch24-notice     | Notice 框架]] | Notice 框架、Notice::Info、告警处理    | ✅  |

---

## Part V：集群部署 (Cluster)

| #   | 章节                  | 主题       | 状态                                          |
| --- | --------------------- | ---------- | --------------------------------------------- | --- |
| 25  | [[ch25-cluster-arch   | 集群架构]] | manager/proxy/p logger/worker 角色、集群拓扑  | ✅  |
| 26  | [[ch26-cluster-config | 集群配置]] | node.cfg / cluster-layout.zeek 配置、流量分发 | ✅  |
| 27  | [[ch27-communication  | 通信]]     | ZeekControl 协议、Broker 通信框架             | ✅  |
| 28  | [[ch28-load-balancing | 负载均衡]] | PF_RING / af_packet 负载均衡、Flow 哈希       | ✅  |
| 29  | [[ch29-packet-loss    | 丢包处理]] | 丢包检测、Intel E810 / DAG 卡、Tshooting      | ✅  |

---

## Part VI：自定义开发 (Customization)

| #   | 章节                                       | 主题         | 状态                                      |
| --- | ------------------------------------------ | ------------ | ----------------------------------------- | --- |
| 30  | [[ch30-script-plugin                       | 脚本插件]]   | Zeek Plugin 结构、**load**.zeek、配置钩子 | 🚧  |
| 31  | [[2026-04-15-zeek-deep-dive-ch31-binar插件 | 二进制插件]] | C++ Binpac 协议解析器、Analyzer 框架      | 🚧  |
| 32  | [[ch32-zkg                                 | ZKG]]        | zeek pkg 命令、package.json、发布分享     | 🚧  |
| 33  | [[ch33-iosource                            | I/O Source]] | 自定义 Input.Reader、日志输入插件         | 🚧  |

---

## Part VII：性能调优 (Performance)

| #   | 章节            | 主题          | 状态                                         |
| --- | --------------- | ------------- | -------------------------------------------- | --- |
| 34  | [[ch34-memory   | 内存调优]]    | memory.log、malloc_trim、jemalloc / mimalloc | 🚧  |
| 35  | [[ch35-scripts  | 脚本优化]]    | 事件处理开销、profile.log、脚本 profiling    | 🚧  |
| 36  | [[ch36-hardware | 硬件加速]]    | Intel FDIR / OpenOnload / DPDK 加速          | 🚧  |
| 37  | [[ch37-tuning   | Tuning 清单]] | 生产调优 checklist、高吞吐量配置             | 🚧  |

---

## Part VIII：日志深度 (Log Analysis)

| #   | 章节           | 主题        | 状态                                         |
| --- | -------------- | ----------- | -------------------------------------------- | --- |
| 38  | [[ch38-eve     | EVE 格式]]  | EVE-JSON 格式、Suricata EVE 对比             | ✅  |
| 39  | [[ch39-hunting | 威胁狩猎]]  | 日志分析、MITRE ATT&CK 映射、IOC 提取        | ✅  |
| 40  | [[ch40-siem    | SIEM 集成]] | Elasticsearch / Splunk / Chronicle SIEM 集成 | ✅  |

---

## Part IX：高级话题 (Advanced)

| #   | 章节                                      | 主题       | 状态                                   |
| --- | ----------------------------------------- | ---------- | -------------------------------------- | --- |
| 41  | [[2026-04-15-zeek-deep-dive-ch41-geoip    | GeoIP]]    | GeoIP2 数据库、位置日志、ASN 追踪      | 🚧  |
| 42  | [[2026-04-15-zeek-deep-dive-ch42-intel    | 情报整合]] | Intel Framework、IOC 匹配、威胁情报    | 🚧  |
| 43  | [[2026-04-15-zeek-deep-dive-ch43-software | 软件指纹]] | Software Framework、版本检测、指纹库   | 🚧  |
| 44  | [[2026-04-15-zeek-deep-dive-ch44-ot       | OT 协议]]  | Modbus / DNP3 / IEC 61850 工控协议分析 | 🚧  |

---

## Part X：Zeek 与 Suricata 对比 (Comparison)

| #   | 章节                    | 主题               | 状态                       |
| --- | ----------------------- | ------------------ | -------------------------- | --- |
| 45  | [[ch45-zeek-vs-suricata | Zeek vs Suricata]] | 两种框架对比、联合部署场景 | 🚧  |

---

## 相关系列

- [[suricata-deep-dive|Suricata 深度探索系列]] — 规则驱动 IDS
- [[dpdk-deep-dive|DPDK 深度探索系列]] — 高性能数据包处理
- [[cilium-deep-dive|Cilium 深度探索系列]] — eBPF 云原生网络
