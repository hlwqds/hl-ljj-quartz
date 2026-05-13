---
title: "Zeek 深度探索 (三)：配置系统"
date: 2026-04-15
tags:
  - zeek
  - series
  - config
  - zeekctl
  - zeek_path
  - zeek_scripts
description: "深入解析 Zeek 的配置系统——zeekctl 配置、node.cfg 节点配置、zeek_path 脚本加载机制、内置配置变量，以及配置如何驱动源码行为"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. **第三章：配置系统**
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]

---

## 1. 配置系统概述

Zeek 的配置系统分为**三层**：

```
┌─────────────────────────────────────────┐
│  Layer 3: zeekctl 配置                   │
│  (zeekctl.cfg / node.cfg)               │
├─────────────────────────────────────────┤
│  Layer 2: ZeekScript 配置               │
│  @(prefix)-options.zeek / zeekctl      │
├─────────────────────────────────────────┤
│  Layer 1: ZeekScript 内置变量            │
│  scripts/base/init-*.zeek               │
└─────────────────────────────────────────┘
```

- **Layer 1**：`scripts/base/init-*.zeek` 定义了 Zeek 的内置配置变量（如 `$listen_addresses`、`$connection_types`）
- **Layer 2**：用户通过 `@(prefix)-options.zeek` 或 zeekctl 的 `send-command` 设置选项
- **Layer 3**：zeekctl 本身的配置文件，控制 zeek 进程管理

---

## 2. zeekctl 配置

### 2.1 zeekctl.cfg 详解

```ini
# etc/zeekctl.cfg

[zeek]
# Zeek 二进制文件所在目录
bindir = ${scriptdir}/../bin

# Zeek 脚本所在目录（zeek_path）
scriptdir = ${scriptdir}

# Zeek 插件目录
plugindir = ${scriptdir}/../plugins

# 日志输出根目录
logdir = /var/log/zeek

# Spool 目录（进程状态文件）
spooldir = /var/spool/zeek

# PID 文件目录
piddir = ${spooldir}

[agent]
# ZeekControl Agent 配置（集群模式）
# 默认禁用，仅 manager 需要
enabled = false
host = localhost
port = 2157

[mail]
# 告警邮件配置
mailfrom = zeek@localhost
mailto = admin@localhost
mailhost = localhost

[logging]
# 日志写入配置
# stdout: zeekctl / never
stdout = zeekctl

# 日志轮转格式：ascii / json / tabs
rotation_format = json

# 日志轮转间隔（分钟）
rotation_interval = 3600   # 1小时

# 日志压缩
use_compression = true

[production]
# 部署模式
# production: 启用严格检查，阻止危险操作
# standalone: 开发/测试模式
deployment = standalone

[stat]
# 状态更新间隔（秒）
interval = 10

[tuning]
# 性能调优参数（传递给 zeek 命令行）
# 默认空，可设置 -C（checksum checks）、-U（stop陇不缓存）
default_options =

[broker]
# Broker 通信配置
# 禁用时报错：Broker not configured
port = 47762

[time]
# 时区
# 本地时间
timezone = local
```

### 2.2 node.cfg 详解

```ini
# etc/node.cfg — 单节点 standalone

[zeek]
type = standalone
host = localhost
interface = eth0

# 或使用 pcap 文件测试
# interface = /path/to/capture.pcap
```

**多节点集群配置**：

```ini
# etc/node.cfg — 多节点集群

[manager]
type = manager
host = 192.168.1.10
# manager 节点不需要 interface

[proxy-1]
type = proxy
host = 192.168.1.11

[worker-1]
type = worker
host = 192.168.1.12
interface = eth0

# 负载均衡方法：
#   - pf_ring (PF_RING 负载均衡)
#   - myricom (Myricom SNF)
#   - af_packet (AF_XDP 负载均衡)
#   - none (单进程，无 LB)
lb_method = pf_ring

# worker 进程数
lb_procs = 4

# CPU 亲和性（可选）
# cpulist = 0,1,2,3

[worker-2]
type = worker
host = 192.168.1.13
interface = eth0
lb_method = pf_ring
lb_procs = 4
```

---

## 3. ZeekScript 配置选项系统

Zeek 5.0 引入了 **Option 系统**，提供类型化的配置选项。

### 3.1 内置选项示例

```zeek
# scripts/base/init.zeek 中的内置选项

# 全局选项（通过 @if 用于条件加载）
global listening_addresses: set[addr] = { 127.0.0.1, ::1 };

# 日志选项
option log_encrypted_conns = T;
option log_http = T;
option log_dns = T;
option log_tls = T;

# 检测选项
option detect_dos = F;
option detect_scan = T;

# 阈值选项
option http_max_length = 10000000;  # 10MB
option dns_max_length = 16384;       # 16KB
```

### 3.2 定义自定义选项

```zeek
# site/my-options.zeek

@load base/frameworks/notice

module MyPolicy;

export {
    # 定义选项（类型化）
    option enable_http_logging = T;
    option suspicious_http_hosts: set[string] = {};
    option http_rate_threshold = 100;
    option intel_check_zeek = T;
}

# 使用选项
event http_request(c: connection, method: string, original_URI: string, version: string) {
    if (enable_http_logging) {
        print fmt("HTTP %s %s", method, original_URI);
    }
}
```

### 3.3 zeekctl 运行时修改选项

```bash
# 通过 zeekctl 发送命令修改选项
zeekctl
> send MyPolicy::enable_http_logging = F

# 查看当前选项值
zeekctl
> print MyPolicy::enable_http_logging
```

### 3.4 zeek 命令行选项

```bash
# 直接运行 zeek 的关键选项
zeek [options]

# 核心选项
-i <interface>          # 监听接口
-r <pcapfile>           # 读取 pcap 文件
-w <outfile>            # 输出 pcap 文件
-B <filter>             # BPF 过滤器
-C                      # 不校验 TCP 校验和
-U <uri>                # 不缓存状态的 URI

# 脚本加载选项
-s <scripts.zeek>       # 加载站点脚本
-t <topic>              # 加载单个脚本
-Z <topic>              # 不加载某脚本
@<script>               # 在命令行加载脚本

# 输出选项
-g                      # 调试输出
-v                      # verbose 模式
-d                      # debug 模式
```

---

## 4. 脚本加载机制

### 4.1 zeek_path 搜索路径

Zeek 脚本加载依赖 `zeek_path` 环境变量或内置配置：

```bash
# 查看默认 zeek_path
zeek --print-zeek-path

# 输出示例：
# /usr/local/zeek/share/zeek/site:/usr/local/zeek/share/zeek/base:/usr/local/zeek/share/zeek/policy
```

**zeek_path 优先级**（按顺序）：

1. **绝对路径**：`/abs/path/to/script.zeek`
2. **zeek_path 相对路径**：在 `$ZEEKBASE/share/zeek/base/` 等目录查找
3. **@load 指令**：显式加载

### 4.2 @load 指令

```zeek
# 加载基础脚本
@load base/frameworks/dpd

# 加载 policy 脚本
@load policy/protocols/http/auth

# 加载本地 site 脚本
@load site/my-detection-script

# 有条件加载
@if ( Cluster::enabled )
    @load policy/cluster/worker
@endif
```

### 4.3 加载顺序

Zeek 脚本加载分为 **stage**：

```
Stage 1: init-bare.zeek        # 最简初始化
Stage 2: base/                 # 基础框架
Stage 3: policy/               # 策略脚本
Stage 4: site/                 # 本地脚本
Stage 5: 命令行 @load          # 显式加载
```

**init-bare.zeek** 的核心加载：

```zeek
# scripts/base/init-bare.zeek 核心片段

# 加载基础协议分析器
@load base/protocols/http
@load base/protocols/dns
@load base/protocols/tls
@load base/protocols/smb
@load base/protocols/ssh
@load base/protocols/ftp
@load base/protocols/smtp

# 加载基础框架
@load base/frameworks/logging
@load base/frameworks/notice
@load base/frameworks/signatures
@load base/frameworks/intel
@load base/frameworks/input
@load base/frameworks Broker
@load base/frameworks cluster
```

### 4.4 zeekctl 部署时的脚本加载

```bash
# zeekctl 启动时传递的脚本
# 实际执行的命令类似：
zeek -i eth0 \
    -s local-site.zeek \
    ${scriptdir}/zeekctl/auto.zeek \
    ${scriptdir}/zeekctl/standalone.zeek \
    ${scriptdir}/zeekctl/cluster.zeek

# auto.zeek 根据 node.cfg 决定加载 standalone 还是 cluster 脚本
```

---

## 5. 核心配置变量（init.zeek）

### 5.1 网络配置

```zeek
# scripts/base/init.zeek

# 默认监听地址
global listening_addresses: set[addr] = { 127.0.0.1, ::1 };

# 站点网络定义（用于检测本地 vs 远程）
option site_local_nets = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 };

# 外部网络
option external_nets = { 0.0.0.0/0, ::/0 };

# 保留地址
option reserved_ports: set[port] = { 67/tcp, 68/udp, 53/tcp, 53/udp };
```

### 5.2 连接跟踪配置

```zeek
# 连接跟踪相关配置
option connection_types: set[string] = { "TCP", "UDP", "ICMP" };

# 连接超时（秒）
option tcp_inactivity_timeout = 5 min;
option udp_inactivity_timeout = 1 min;
option icmp_inactivity_timeout = 1 min;

# 活跃连接最大内存
option max_connection_memory = 50MB;
```

### 5.3 日志配置

```zeek
# scripts/base/frameworks/logging/init.zeek

# 日志过滤器定义
# Log::ID -> filter -> writer

# 默认过滤器
option default_filter = "$default";

# 日志写入间隔（记录数）
option logs_write_interval = 1000;

# ASCII 写入器配置
option ascii_log_use_json = F;
option ascii_log_set_separator = "\x09";  # Tab
option ascii_log_empty_field = "(empty)";
option ascii_log_undef_field = "-";
```

### 5.4 协议分析配置

```zeek
# HTTP 分析配置
option http_log_ignore_user_agents = Set[string]();
option http_log_ignore_hosts = Set[string]();
option http_log_ignore_paths = Set[string]();

# DNS 分析配置
option dns_log_queries = T;
option dns_log_responses = T;
option dns_truncate_response_size = 512;

# TLS 分析配置
option ssl_log_extended_info = F;
option tls_server_method_logging = F;
```

---

## 6. 本地站点配置

### 6.1 local-site.zeek

```bash
# 创建本地配置脚本
# $ZEEKBASE/share/zeek/site/local-site.zeek
# 或 zeekctl 节点配置时指定
```

```zeek
# site/local-site.zeek 示例

@load base/frameworks/notice
@load base/frameworks/intel
@load policy/protocols/http/detect-webapps
@load policy/protocols/ssl/validate-certs
@load policy/protocols/ssh/detect-bruteforcing

# 自定义配置
option enable_file_logging = T;
option intel_check_files = T;

# 添加本地情报
redef Intel::seen += {
    [$indicator = "192.168.1.100", $indicator_type = Intel::ADDR, $meta = [$source = "local"]],
};
```

### 6.2 cluster-layout.zeek（集群）

```zeek
# 显式定义集群拓扑（可选，node.cfg 足够时不需要）
@load base/frameworks/cluster

redef Cluster::nodes = {
    ["manager"] = [$type = Cluster::MANAGER, $host = "192.168.1.10"],
    ["proxy"]   = [$type = Cluster::PROXY,   $host = "192.168.1.11"],
    ["worker-1"] = [$type = Cluster::WORKER, $host = "192.168.1.12", $interface = "eth0", $lb_procs = 4],
    ["worker-2"] = [$type = Cluster::WORKER, $host = "192.168.1.13", $interface = "eth0", $lb_procs = 4],
};
```

---

## 7. 环境变量

### 7.1 关键环境变量

| 变量 | 说明 | 默认值 |
| :--- | :--- | :--- |
| `ZEEKBASE` | Zeek 安装根目录 | `/usr/local/zeek` |
| `ZEEK_PLUGIN_PATH` | 插件搜索路径 | `$ZEEKBASE/plugins` |
| `ZEEKPATH` | ZeekScript 搜索路径 | `$ZEEKBASE/share/zeek/base:...` |
| `ZEEK_DEBUG` | 启用调试输出 | 空 |
| `ZEEK_GOPATH` | Go 插件路径 | 空 |
| `ZEEK_LOG_FILE` | 日志文件 | stderr |

### 7.2 ZEEKPATH 配置

```bash
# 添加自定义脚本目录到搜索路径
export ZEEKPATH=/opt/my-zeek-scripts:$ZEEKPATH

# 验证搜索路径
zeek --print-zeek-path
```

---

## 8. 配置调试

### 8.1 查看加载的脚本

```bash
# 显示所有加载的脚本
zeek -b -N -p | less

# -b: 调试模式
# -N: 打印所有加载的脚本
# -p: 使用本地 site-path
```

### 8.2 查看配置变量值

```bash
# 查看特定变量的值
zeek --eval 'print Site::local_nets;'

# 查看所有内置变量
zeek -b --print-vars | less
```

### 8.3 脚本覆盖率分析

```bash
# 生成 script coverage 报告
zeek -b -s my-script.zeek -p -U <state-file> | head -50
```

---

## 9. 配置迁移（从旧版本）

### 9.1 Zeek 5.x → 7.x 变化

1. **Bro → Zeek 命名迁移**：
   - 配置文件后缀：`.bro` → `.zeek`
   - 命令行：`bro` → `zeek`
   - 环境变量：`BRO_*` → `ZEEK_*`

2. **迁移脚本**：
   ```bash
   # 自动迁移脚本（位于 Zeek 源码）
   ./scripts/migrate-to-zeek.sh /path/to/old/bro-scripts/
   ```

3. **重要配置变化**：

```ini
# Zeek 6.x 以前的 zeekctl.cfg
[General]
BroLogDir = /var/log/zeek

# Zeek 7.x 中
[zeek]
logdir = /var/log/zeek
```

---

## 10. 本章小结

本章深入解析了 Zeek 的三层配置系统：

1. **zeekctl 配置**：zeekctl.cfg 全局参数、node.cfg 节点定义
2. **ZeekScript Option 系统**：类型化配置选项、自定义选项定义
3. **脚本加载机制**：zeek_path 搜索路径、@load 指令、加载阶段
4. **核心配置变量**：网络、连接跟踪、日志、协议分析配置
5. **环境变量**：ZEEKBASE、ZEEKPATH 等关键变量

**下一章**将深入解析 Zeek 的核心架构——事件引擎、协议分析器框架、脚本解释器。
