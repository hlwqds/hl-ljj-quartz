---
title: "Zeek 深度探索 (二十)：连接分析"
date: 2026-04-15
tags:
  - zeek
  - series
  - connection
  - conn.log
  - traffic-analysis
  - state-machine
description: "深入解析 Zeek 连接分析——connection.log、Conn::Info record、连接状态机、连接追踪机制、连接事件"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. [[2026-04-15-zeek-deep-dive-ch4-architecture|第四章：Zeek 架构]]
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]
> 6. [[2026-04-15-zeek-deep-dive-ch6-scriptlang|第六章：ZeekScript 基础]]
> 7. [[2026-04-15-zeek-deep-dive-ch7-events|第七章：事件]]
> 8. [[2026-04-15-zeek-deep-dive-ch8-hooks|第八章：Hooks]]
> 9. [[2026-04-15-zeek-deep-dive-ch9-packages|第九章：Packages]]
> 10. [[2026-04-15-zeek-deep-dive-ch10-debugging|第十章：调试]]
> 11. [[2026-04-15-zeek-deep-dive-ch11-http|第十一章：HTTP 分析]]
> 12. [[2026-04-15-zeek-deep-dive-ch12-dns|第十二章：DNS 分析]]
> 13. [[2026-04-15-zeek-deep-dive-ch13-tls|第十三章：TLS 分析]]
> 14. [[2026-04-15-zeek-deep-dive-ch14-smb|第十四章：SMB 分析]]
> 15. [[2026-04-15-zeek-deep-dive-ch15-ssh|第十五章：SSH 分析]]
> 16. [[2026-04-15-zeek-deep-dive-ch16-ftp|第十六章：FTP 分析]]
> 17. [[2026-04-15-zeek-deep-dive-ch17-smtp|第十七章：SMTP 分析]]
> 18. [[2026-04-15-zeek-deep-dive-ch18-rdp|第十八章：RDP 分析]]
> 19. [[2026-04-15-zeek-deep-dive-ch19-kafka|第十九章：Kafka 集成]]
> 20. **第二十章：连接分析**

---

## 1. 连接分析概述

Zeek 的连接分析是其网络分析的核心。所有通过 Zeek 的流量都会首先被追踪为连接（Connection），然后才由各个协议分析器进行深入分析。

### 1.1 连接追踪位置

```
$ZEEK_HOME/scripts/base/protocols/conn/
├── main.zeek          # 主脚本，连接状态机
├── capstats.zeek      # 包统计
├── known_hosts.zeek   # 已知主机追踪
├── known_services.zeek # 已知服务追踪
└── thresheld.zeek    # 阈值检测
```

### 1.2 连接分析架构

```
┌─────────────────────────────────────────────────────────────┐
│                    连接分析架构                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Packet Capture                                              │
│       ↓                                                      │
│  Packet Processing                                           │
│       ↓                                                      │
│  Connection Tracker (Hash Table)                              │
│       ↓                                                      │
│  ┌──────────────────────────────────────────────────────┐  │
│  │  Connection State Machine                               │  │
│  │  S0 → S1 → S2 → S3 → S4 → S5 → S6 → S7 → Closed      │  │
│  └──────────────────────────────────────────────────────┘  │
│       ↓                                                      │
│  Protocol Analyzers (HTTP, DNS, TLS, ...)                   │
│       ↓                                                      │
│  Conn::Info record 填充                                       │
│       ↓                                                      │
│  connection.log 输出                                          │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 连接日志格式

### 2.1 conn.log 字段详解

`conn.log` 是 Zeek 最基础的日志文件，每个 TCP/UDP/ICMP 连接都会生成一条记录。

```zeek
type Conn::Info = record {
    # 连接标识
    ts: time;                 # 时间戳
    uid: string;              # 连接唯一标识符 (UID)
    id: conn_id;             # 4-tuple (orig_h, orig_p, resp_h, resp_p)

    # 连接状态
    proto: transport_proto;   # 协议 (tcp/udp/icmp)
    service: string;         # 检测到的应用服务
    duration: interval;      # 连接持续时间
    orig_bytes: int64;        # 原始方向字节数
    resp_bytes: int64;       # 响应方向字节数
    conn_state: string;      # 连接状态

    # 本地信息
    local_orig: bool;         # 原始主机是否为本地
    local_resp: bool;        # 响应主机是否为本地

    # missed_bytes: int64;   # 丢失的字节数
    history: string;         # 连接历史状态码

    # 端口信息
    orig_pkts: int64;        # 原始方向数据包数
    resp_pkts: int64;        # 响应方向数据包数
    orig_ip_bytes: int64;    # 原始方向 IP 字节数
    resp_ip_bytes: int64;    # 响应方向 IP 字节数

    # 隧道信息
    tunnel_parents: set[string];  # 隧道父连接 UID

    # 挥击检测
    vlan: count;             # VLAN ID
    inner_vlan: count;       # 内部 VLAN ID

    # 检测信息
    detection_skip: bool;    # 是否跳过检测
} &optional;
```

### 2.2 conn.log 示例

```
#fields ts uid id.orig_h id.orig_p id.resp_h id.resp_p proto service duration orig_bytes resp_bytes conn_state local_orig local_resp history orig_pkts resp_pkts orig_ip_bytes resp_ip_bytes tunnel_parents vlan inner_vlan
1672531200.123456 Cx1234abcd 192.168.1.100 52341 93.184.216.34 443 tcp ssl 2.345 1234 5678 S3 192.168.1.100 93.184.216.34 ShADadfR 10 8 1456 1234 - 0 0
```

### 2.3 主要字段说明

| 字段         | 类型            | 说明                                      |
| ------------ | --------------- | ----------------------------------------- |
| `ts`         | time            | 连接开始时间戳                            |
| `uid`        | string          | 唯一连接标识符                            |
| `id`         | conn_id         | 4-tuple 连接标识                          |
| `proto`      | transport_proto | 传输层协议 (TCP/UDP/ICMP)                 |
| `service`    | string          | 检测到的服务 (http, dns, smtp, ssh, etc.) |
| `duration`   | interval        | 连接持续时长                              |
| `orig_bytes` | int64           | 源到目标字节数                            |
| `resp_bytes` | int64           | 目标到源字节数                            |
| `conn_state` | string          | 连接最终状态                              |
| `history`    | string          | 连接状态转换历史                          |

---

## 3. 连接状态机

### 3.1 TCP 连接状态

Zeek 使用简化的 TCP 状态机，状态码含义：

| 状态码 | 含义                     | TCP 状态       |
| ------ | ------------------------ | -------------- |
| `S0`   | 连接建立，但未见响应     | SYN sent       |
| `S1`   | 连接建立，未见关闭       | Established    |
| `S2`   | 连接关闭，本地发送 FIN   | Fin wait 1     |
| `S3`   | 连接关闭，本地接收 FIN   | Fin wait 2     |
| `S4`   | 连接关闭，本地发送 RST   | Reset          |
| `S5`   | 连接关闭，响应方发送 FIN | Closing        |
| `S6`   | 响应方发送 FIN，本地确认 | Close wait     |
| `S7`   | 双方 FIN 交换完成        | Last ack       |
| `S8`   | 仅响应方发送 FIN         | Time wait      |
| `S9`   | 本地发送 FIN 后收到 RST  | Fin wait + RST |
| `S10`  | 响应方发送 RST           | Reset          |
| `S11`  | 连接超时                 | Timeout        |
| `S12`  | 检测到半开连接           | Half-open      |
| `OTH`  | 其他 ICMP 不可达         | -              |

### 3.2 连接状态转移图

```
                    ┌───────────────────────────────────────┐
                    │                                       │
                    ↓                                       │
    ┌───────┐   SYN   ┌───────┐                          │
    │ CLOSED │ ──────→│  S0   │                          │
    └───────┘         └───────┘                          │
                            │                            │
                            │ SYN-ACK                     │
                            ↓                            │
                    ┌───────────────┐                    │
    ┌───────┐       │               │                    │
    │  S4   │←──RST─│      S1       │                    │
    └───────┘       │  (Established) │                    │
                    └───────────────┘                    │
                            │                            │
              ┌─────────────┼─────────────┐              │
              │             │             │              │
          FIN (local)   FIN (remote)   RST              │
              │             │             │              │
              ↓             ↓             ↓              │
        ┌───────────┐ ┌───────────┐ ┌───────────┐      │
        │    S2     │ │    S6     │ │    S4     │      │
        │(Fin wait1)│ │(Close wait)│ │  (RST)    │      │
        └───────────┘ └───────────┘ └───────────┘      │
              │             │                            │
              │ ACK         │ FIN                        │
              ↓             ↓                            │
        ┌───────────┐ ┌───────────┐                    │
        │    S3     │ │    S5     │                    │
        │(Fin wait2)│ │ (Closing) │                    │
        └───────────┘ └───────────┘                    │
              │             │                            │
              │ FIN         │ ACK                        │
              └──────┬──────┘                            │
                     │                                   │
                     │ ACK                               │
                     ↓                                   │
               ┌───────────┐                             │
               │    S7     │                             │
               │(Last ack) │                             │
               └───────────┘                             │
                     │                                   │
                     │ ACK                               │
                     ↓                                   │
               ┌───────────┐                             │
               │   S8      │                             │
               │(Time wait)│                            │
               └───────────┘                             │
                     │                                   │
                     │ Timeout                           │
                     ↓                                   │
               ┌───────────┐                             │
               │  CLOSED   │                             │
               └───────────┘                             │
```

### 3.3 history 字段

`history` 字段记录连接的状态转换，使用字符码：

| 字符 | 含义                  |
| ---- | --------------------- |
| `S`  | SYN                   |
| `H`  | SYN-ACK handshake     |
| `A`  | ACK                   |
| `D`  | 数据传输 (Data)       |
| `F`  | FIN                   |
| `R`  | RST                   |
| `C`  | 乱序 (Chunk)          |
| `T`  | 重传 (Retransmission) |
| `I`  | 空闲 (Idle)           |
| `Q`  | 纯 ACK (Query)        |

例如：`ShADadfR` 表示 SYN → SYN-ACK → ACK → Data → Data → FIN → RST

---

## 4. 连接事件

### 4.1 connection_established 事件

```zeek
event connection_established(c: connection)
```

TCP 三次握手完成，连接进入 Established 状态时触发。

```zeek
event connection_established(c: connection)
    {
    print fmt("[CONN] Connection established: %s -> %s",
              c$id$orig_h, c$id$resp_h);

    # 记录连接开始时间
    print fmt("[CONN] Service detected: %s", c$service);
    }
```

### 4.2 connection_attempted 事件

```zeek
event connection_attempted(c: connection)
```

连接尝试建立（SYN 发送）时触发。

```zeek
event connection_attempted(c: connection)
    {
    print fmt("[CONN] Connection attempt: %s:%d -> %s:%d",
              c$id$orig_h, c$id$orig_p,
              c$id$resp_h, c$id$resp_p);
    }
```

### 4.3 connection_rejected 事件

```zeek
event connection_rejected(c: connection)
```

连接被拒绝（RST 或 ICMP）时触发。

```zeek
event connection_rejected(c: connection)
    {
    print fmt("[CONN] Connection rejected: %s -> %s (state: %s)",
              c$id$orig_h, c$id$resp_h, c$conn_state);

    # 可能需要告警
    if (c$id$resp_p == 445) {
        NOTICE([$note = SMB_CONN_REJECTED,
                $msg = fmt("SMB connection rejected from %s", c$id$orig_h),
                $conn = c]);
    }
    }
```

### 4.4 connection_state_remove 事件

```zeek
event connection_state_remove(c: connection)
```

连接关闭，从连接表中移除时触发。这是连接生命周期的最后一个事件。

```zeek
event connection_state_remove(c: connection)
    {
    # 记录连接摘要
    print fmt("[CONN] Connection closed: %s -> %s (%s, duration: %s, bytes: %d/%d)",
              c$id$orig_h, c$id$resp_h,
              c$conn_state, c$duration,
              c$orig_bytes, c$resp_bytes);

    # 检测异常连接
    if (c$duration > 1day) {
        print fmt("[CONN] Long duration connection detected");
    }
    }
```

### 4.5 connection_half_connection 事件

```zeek
event connection_half_connection(c: connection)
```

检测到半开连接（一端发送 FIN 但未收到 ACK）。

```zeek
event connection_half_connection(c: connection)
    {
    print fmt("[CONN] Half-open connection: %s -> %s",
              c$id$orig_h, c$id$resp_h);

    NOTICE([$note = HALF_OPEN_CONNECTION,
            $msg = fmt("Half-open TCP connection: %s -> %s",
                      c$id$orig_h, c$id$resp_h),
            $conn = c]);
    }
```

### 4.6 weird_activity 事件

```zeek
event weird_activity(name: string, c: connection, addl: string)
```

检测到连接异常活动时触发。

```zeek
event weird_activity(name: string, c: connection, addl: string)
    {
    print fmt("[WEIRD] %s: %s -> %s (%s)",
              name, c$id$orig_h, c$id$resp_h, addl);
    }
```

---

## 5. 连接追踪机制

### 5.1 连接表

Zeek 使用全局连接表维护所有活动连接：

```zeek
# 连接表类型
global connections: table[conn_id] of connection;
```

连接表按 4-tuple（源 IP、源端口、目标 IP、目标端口）索引。

### 5.2 连接标识

```zeek
type conn_id = record {
    orig_h: addr;      # 源 IP
    orig_p: port;     # 源端口
    resp_h: addr;     # 目标 IP
    resp_p: port;     # 目标端口
};
```

### 5.3 连接结构

```zeek
type connection = record {
    # 基本标识
    id: conn_id;           # 4-tuple
    uid: string;           # 唯一标识符

    # 状态
    orig: endpoint;        # 源端点状态
    resp: endpoint;        # 目标端点状态
    start_time: time;      # 开始时间
    duration: interval;    # 持续时间

    # 服务
    service: set[string];  # 检测到的服务

    # 状态
    state: connection_state;  # 连接状态
    history: string;          # 状态历史

    # 协议分析器数据
    http: HTTP::Info &optional;
    dns: DNS::Info &optional;
    ssl: SSL::Info &optional;
    ssh: SSH::Info &optional;
    smtp: SMTP::Info &optional;
    # ... 其他协议

    # 文件
    files: table[string] of fa_file;  # 文件 UID -> 文件

    # 隧道
    tunnel: bool;              # 是否隧道
    tunnel_parent: string &optional;  # 父连接 UID

    # 标签
    tags: set[string];         # 连接标签
    logged: bool;              # 是否已记录
};
```

### 5.4 端点状态

```zeek
type endpoint = record {
    # 统计
    pkts: int64;              # 数据包数
    bytes: int64;             # 字节数
    IP_bytes: int64;           # IP 层字节数

    # 状态
    state: endpoint_state;     # 端点状态
    flags: endpoint_flags;     # 端点标志

    # 检测
    seq: count;                # 下一个期望序列号
    ack: count;                # 确认号
    last_seq: count;           # 最后序列号
    last_time: time;           # 最后活动时时间

    # 窗口
    win: count;                # 窗口大小
    win_scale: count;          # 窗口缩放因子
};
```

---

## 6. 服务检测

### 6.1 端口与服务映射

Zeek 维护端口到服务的默认映射：

```zeek
# 默认服务端口
redef default_service_ports = {
    [21/tcp] = "ftp",
    [22/tcp] = "ssh",
    [23/tcp] = "telnet",
    [25/tcp] = "smtp",
    [53/tcp] = "dns",
    [53/udp] = "dns",
    [80/tcp] = "http",
    [443/tcp] = "ssl",
    [445/tcp] = "smb",
    [3306/tcp] = "mysql",
    [3389/tcp] = "rdp",
    [5432/tcp] = "pgsql",
    [6379/tcp] = "redis",
    [8080/tcp] = "http",
};
```

### 6.2 动态服务检测

协议分析器会动态检测服务类型：

```zeek
# HTTP 分析器检测到 HTTP 流量时
event http_request(c: connection, method: string, original_uri: string, version: string)
    {
    # 添加 http 服务标识
    add c$service["http"];
    }
```

### 6.3 服务覆盖

可以覆盖默认端口分配：

```zeek
# 让 Zeek 将 8080 端口的流量当作 HTTP 分析
redef likely_server_ports += { 8080/tcp };
```

---

## 7. 连接配置选项

### 7.1 基础配置

```zeek
# 连接超时
redef Conn::activity_timeout = 5min;     # 活动超时
redef Conn::remove_connection_after = 5mins;  # 移除超时

# 缓冲区大小
redef Conn::max_initial_ouput_buffer_size = 128KB;
redef Conn::max_output_buffer_size = 512KB;

# 状态机
redef Conn::use_conn_size_analyzer = T;
redef Conn::size_threshold = 200MB;  # 触发大小分析
```

### 7.2 日志配置

```zeek
# 日志详细程度
redef Conn::log_connection_state = F;     # 记录连接状态
redef Conn::log_connection_ip_lengths = F;  # 记录 IP 长度
redef Conn::log_connection_contents = F;    # 记录内容

# 持久化连接日志
redef Conn::log_incomplete_connections = F;
```

### 7.3 过滤配置

```zeek
# 过滤某些连接
redef Conn::ignore_conn_interface = "";    # 忽略特定接口

# 特定网段不记录
redef Conn::no_session_keys: set[conn_id] = {};
```

---

## 8. 连接分析实战

### 8.1 统计连接数

```zeek
global connection_count = 0;
global connections_by_proto: table[string] of count;

event connection_state_remove(c: connection)
    {
    connection_count += 1;

    local proto = fmt("%s/%s", c$id$resp_p$proto, c$id$resp_p$port);
    if (proto !in connections_by_proto) {
        connections_by_proto[proto] = 0;
    }
    connections_by_proto[proto] += 1;

    if (connection_count % 1000 == 0) {
        print fmt("[STATS] Total connections: %d", connection_count);
        for (proto in connections_by_proto) {
            print fmt("[STATS] %s: %d", proto, connections_by_proto[proto]);
        }
    }
    }
```

### 8.2 检测端口扫描

```zeek
global scan_sources: table[addr] of set[addr];
global scan_threshold = 100;

event connection_attempted(c: connection)
    {
    local src = c$id$orig_h;
    local dst = c$id$resp_h;

    # 记录扫描源尝试的所有目标
    if (src !in scan_sources) {
        scan_sources[src] = set();
    }
    add scan_sources[src][dst];

    # 检测扫描行为
    if (|scan_sources[src]| > scan_threshold) {
        NOTICE([$note = PORTSCAN,
                $msg = fmt("Port scan from %s: %d targets",
                          src, |scan_sources[src]|),
                $conn = c]);
    }
    }
```

### 8.3 检测高带宽连接

```zeek
global high_bandwidth_threshold = 1GB;

event connection_state_remove(c: connection)
    {
    local total_bytes = c$orig_bytes + c$resp_bytes;

    if (total_bytes > high_bandwidth_threshold) {
        print fmt("[BANDWIDTH] High bandwidth: %s -> %s: %s total",
                  c$id$orig_h, c$id$resp_h,
                  fmt("%.2f GB", double(total_bytes) / 1GB));

        NOTICE([$note = HIGH_BANDWIDTH_CONNECTION,
                $msg = fmt("High bandwidth connection: %s <-> %s: %s",
                          c$id$orig_h, c$id$resp_h,
                          fmt("%.2f GB", double(total_bytes) / 1GB)),
                $conn = c]);
    }
    }
```

### 8.4 检测长时间连接

```zeek
global long_connection_threshold = 1day;

event connection_state_remove(c: connection)
    {
    if (c$duration > long_connection_threshold) {
        print fmt("[CONN] Long connection: %s -> %s: duration=%s, bytes=%d/%d",
                  c$id$orig_h, c$id$resp_h,
                  c$duration, c$orig_bytes, c$resp_bytes);

        NOTICE([$note = LONG_CONNECTION,
                $msg = fmt("Long duration connection: %s -> %s: %s",
                          c$id$orig_h, c$id$resp_h, c$duration),
                $conn = c]);
    }
    }
```

### 8.5 检测可疑连接状态

```zeek
event connection_state_remove(c: connection)
    {
    # 检测异常状态关闭
    if (c$conn_state == "S4" && c$orig_bytes == 0 && c$resp_bytes == 0) {
        print fmt("[CONN] Empty RST connection: %s -> %s",
                  c$id$orig_h, c$id$resp_h);

        NOTICE([$note = SUSPICIOUS_CONNECTION,
                $msg = fmt("Empty RST connection: %s -> %s",
                          c$id$orig_h, c$id$resp_h),
                $conn = c]);
    }

    # 检测 S0 状态（只发 SYN 无响应）
    if (c$conn_state == "S0" && c$resp_pkts == 0) {
        print fmt("[CONN] Unresponsive host: %s (target: %s)",
                  c$id$resp_h, c$id$orig_h);
    }
    }
```

---

## 9. 连接与协议分析器

### 9.1 连接上下文传递

协议分析器通过连接记录共享状态：

```
TCP Connection
    ↓
HTTP Analyzer
    ↓ (adds c$http)
SSH Analyzer
    ↓ (adds c$ssh)
SSL Analyzer
    ↓ (adds c$ssl)
Connection Record (c$http, c$ssh, c$ssl, ...)
    ↓
conn.log + http.log + ssh.log + ssl.log
```

### 9.2 访问协议数据

```zeek
event connection_state_remove(c: connection)
    {
    # 检查 HTTP 信息
    if (c?$http) {
        print fmt("[CONN] HTTP: %s %s -> %s (status: %d)",
                  c$http$method, c$http$uri,
                  c$id$resp_h, c$http$status_code);
    }

    # 检查 TLS 信息
    if (c?$ssl) {
        print fmt("[CONN] TLS: %s (cipher: %s)",
                  c$ssl$server_name, c$ssl$cipher);
    }
    }
```

### 9.3 协议与服务联动

```zeek
event http_request(c: connection, method: string, original_uri: string, version: string)
    {
    # 确保连接记录了 http 服务
    add c$service["http"];

    # 检查是否意外协议
    if (c$id$resp_p != 80/tcp && c$id$resp_p != 8080/tcp) {
        print fmt("[HTTP] Unexpected HTTP on port %s: %s", c$id$resp_p, original_uri);
    }
    }
```

---

## 10. 小结

本章介绍了 Zeek 连接分析的核心机制：

| 组件           | 说明                                                                     |
| -------------- | ------------------------------------------------------------------------ |
| **conn.log**   | 所有流量的基础日志，包含 4-tuple、字节数、持续时间、状态                 |
| **Conn::Info** | 连接信息的 record 类型                                                   |
| **连接状态机** | S0-S12 状态码，记录 TCP 状态转换                                         |
| **history**    | 连接状态历史，使用字符码记录事件序列                                     |
| **连接事件**   | connection_established, connection_attempted, connection_state_remove 等 |

连接分析是 Zeek 的基础：

- 所有协议分析器依赖连接追踪
- 连接日志是安全分析的重要数据源
- 连接状态和 history 可用于检测扫描、异常连接
- 配合其他协议日志可进行深度威胁分析

下一章我们将讨论 Weird 日志——Zeek 如何检测和处理网络异常。
