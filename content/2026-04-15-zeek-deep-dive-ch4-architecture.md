---
title: "Zeek 深度探索 (四)：Zeek 架构"
date: 2026-04-15
tags:
  - zeek
  - series
  - architecture
  - event-engine
  - analyzer
  - scripting
  - zeekscript
description: "深入解析 Zeek 核心架构——C++ 核心引擎、事件引擎、ZeekScript 解释器、Analyzer 分析器框架、协议分用机制"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
>
> 1. [[2026-04-15-zeek-deep-dive-ch1-overview|第一章：Zeek 概述]]
> 2. [[2026-04-15-zeek-deep-dive-ch2-installation|第二章：安装部署]]
> 3. [[2026-04-15-zeek-deep-dive-ch3-config|第三章：配置系统]]
> 4. **第四章：Zeek 架构**
> 5. [[2026-04-15-zeek-deep-dive-ch5-logging|第五章：日志系统]]

---

## 1. 整体架构

Zeek 采用 **双层架构**：C++ 核心层负责高性能数据包处理和协议解析，ZeekScript 脚本层负责策略分析和日志输出。

```
┌─────────────────────────────────────────────────────────┐
│              ZeekScript 脚本层（解释型语言）              │
│  ┌─────────────────────────────────────────────────┐    │
│  │  Event Handlers / Hooks / Functions / Types    │    │
│  └─────────────────────────────────────────────────┘    │
│                         ↑ 事件 + 回调                    │
├─────────────────────────┼───────────────────────────────┤
│               C++ 核心引擎层（编译型，高性能）             │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐        │
│  │ Packet    │→ │  Event    │→ │  Analyzer    │        │
│  │ Manager   │  │  Engine   │  │  Framework   │        │
│  └──────────┘  └──────────┘  └──────────────┘        │
│         ↑                                             │
│  ┌──────┴────────────────────────────────────────┐    │
│  │           Network I/O（libpcap / AF_XDP）      │    │
│  └─────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

---

## 2. C++ 核心引擎

### 2.1 源码结构（src/）

```
src/
├── main.cc               # 程序入口
├── Event.cc/.h           # 事件引擎核心
├── EventHandler.cc/.h    # 事件处理程序表
├── EventMgr.cc/.h       # 事件管理器
├── NetSessions.cc/.h    # 会话管理器（connection map）
├── Connection.cc/.h     # 连接对象
├── Timer.cc/.h          # 定时器（超时管理）
├── UDPManager.cc/.h     # UDP 会话管理
├── Analyzer.cc/.h       # 分析器基类
├── AnalyzerManager.cc/.h # 分析器管理器
├── (analyzers/)          # 协议分析器实现
│   ├── HTTP.cc/.h
│   ├── DNS.cc/.h
│   ├── TLS.cc/.h
│   └── ...
└── (io/)                 # I/O 引擎
    ├── PktDumper.cc/.h
    ├── PktSrc.cc/.h
    └── ...
```

### 2.2 main.cc 入口流程

```cpp
// src/main.cc — Zeek 主程序流程

int main(int argc, char* argv[])
    {
    // 1. 初始化
    zeek::peery->Setup();
    // - 解析命令行参数
    // - 加载 zeekctl 配置
    // - 初始化 zeek_path

    // 2. 初始化 I/O
    iosource::PktSrc::Register();
    // - 注册 libpcap、AF_XDP 等数据包源

    // 3. 创建事件引擎
    // - 创建 PacketManager
    // - 创建 SessionMap（连接表）
    // - 初始化定时器队列

    // 4. 加载 ZeekScript
    {
    // - 执行 zeek -b init-bare.zeek
    // - 编译 ZeekScript 脚本
    // - 注册事件处理程序
    }

    // 5. 启动 I/O 循环
    // - DispatchLoop()
    // - 循环：抓包 → 分用 → 事件派发
    }
```

### 2.3 Packet Manager

Packet Manager 负责从网络接口抓取数据包：

```cpp
// src/PacketManager.h 核心接口

class PacketManager {
public:
    // 注册数据包源
    void RegisterPktSrc(iosource::PktSrc* src);

    // 抓取并处理下一个数据包
    bool NextPacket();

    // 分用数据包到会话
    void ProcessPacket();

private:
    std::vector<iosource::PktSrc*> pkt_srcs;  // 数据包源列表
    std::map<int, IPPacket*> pending_packets;   // 等待处理的数据包
};
```

**支持的 Packet Source**：

| 类型      | 源码位置            | 说明                |
| :-------- | :------------------ | :------------------ |
| `libpcap` | `src/io/pktSrc.bro` | 通用抓包，默认      |
| `AF_XDP`  | `src/io/AF_XDP.cc`  | 零拷贝，Linux 4.18+ |
| `PF_RING` | `src/io/PF_RING.cc` | 高性能 DNA          |
| `Myricom` | `src/io/Myricom.cc` | SNF 库              |
| `HPV`     | `src/io/HPV.cc`     | Solaris/illumos     |

---

## 3. 事件引擎（Event Engine）

### 3.1 事件循环

事件引擎是 Zeek 的心脏，负责将数据包转化为**事件（Event）** 并派发给脚本层：

```cpp
// src/EventEngine.h — 核心结构

class EventEngine {
public:
    // 处理数据包
    void ProcessPacketPacket(Packet* pkt);

    // 派发事件到队列
    void Dispatch(Event* event);

    // 处理定时器
    void ProcessTimers();

private:
    // 会话表（5-tuple → Connection*）
    SessionMap* sessions;

    // 事件队列
    EventQueue* event_queue;

    // 定时器队列
    TimerMgr* timer_mgr;
};
```

### 3.2 事件派发流程

```
数据包到达（IP Packet）
        ↓
IP Header 解析（IPv4 / IPv6）
        ↓
判断协议（TCP / UDP / ICMP / ...)
        ↓
查找/创建会话（SessionMap lookup by 5-tuple）
        ↓
TCP/UDP Header 解析
        ↓
更新会话状态
        ↓
派发协议事件（tcp_packet / udp_datagram / icmp）
        ↓
Analyzer::ForwardPacket()
        ↓
协议特定事件（http_request / dns_query / tls_handshake）
```

### 3.3 事件队列

```cpp
// src/Event.h

class Event {
public:
    const char* name;       // 事件名称（字符串指针）
    Args* args;             // 事件参数（Val* 列表）
    double time;            // 事件时间戳

    // 链表节点（用于队列）
    Event* next;
    Event* prev;
};

class EventQueue {
public:
    void Enqueue(Event* event);
    Event* Dequeue();
    bool Dispatch();
    size_t Size() const;

private:
    Event* head;
    Event* tail;
    size_t size;
};
```

**事件派发模式**：

- **同步派发**：在数据包处理循环中直接调用（当前事件处理完再继续）
- **异步派发**：将事件放入队列，稍后批量处理

### 3.4 核心事件列表

```cpp
// src/events.bro — 内置事件定义

// 连接生命周期
event connection_established(c: connection);
event connection_attempt(c: connection);
event connection_finished(c: connection);
event connection_state_remove(c: connection);
event connection_reset(c: connection);

// TCP 事件
event tcp_packet(c: connection, p: pkt_hdr);
event new_connection(c: connection);
event connection_SYN(c: connection);
event connection_SYN_ACK(c: connection);
event connection_half_finished(c: connection);

// 应用层事件
event http_request(c: connection, method: string, URI: string, version: string);
event http_reply(c: connection, status_code: int, reason: string);
event dns_query(c: connection, query: string, qtype: int);
event dns_reply(c: connection, query: string, rcode: int);
event ssl_handshake(c: connection, version: int);
event ssh_authentication(c: connection, accepted: bool);
```

---

## 4. 会话管理（Connection / Session）

### 4.1 SessionMap 结构

Zeek 通过 **SessionMap**（5-tuple → Connection\*）管理活跃连接：

```cpp
// src/NetSessions.h

class NetSessions {
public:
    // 查找会话（5-tuple 精确匹配）
    Connection* Lookup(const IPAddr& src, const IPAddr& dst,
                       uint16_t sport, uint16_t dport, Protocol proto);

    // 查找或创建会话
    Connection* FindOrBuildConnection(const Packet* pkt);

    // 遍历所有会话
    void Insert(Connection* conn);
    void Remove(Connection* conn);

    // 内存压力时剔除旧会话
    void Drain();

private:
    // 哈希表实现
    std::unordered_map<FlowKey, Connection*> session_map;
};
```

### 4.2 Connection 对象

```cpp
// src/Connection.h

class Connection : public OpaqueVal {
public:
    // 标识信息
    ConnectionID id;           // 5-tuple
    uid_t uid;                  // 唯一 ID（Zeek 分配）

    // 状态
    ConnectionState state;      // 状态机
    double start_time;          // 建立时间
    double last_time;           // 最后活动

    // 协议分析器
    std::vector<Analyzer*> analyzers;

    // 统计数据
    uint64_t orig_bytes;        // 源端字节数
    uint64_t resp_bytes;        // 响应字节数
    uint64_t orig_pkts;         // 源端包数
    uint64_t resp_pkts;         // 响应包数

    // 应用层信息
    RecordValPtr hiservice;     // 历史服务
    RecordValPtr servicemask;  // 服务掩码

    // 事件历史（用于检测）
    std::vector<Event*> event_history;

    // 连接定位器（Cluster）
    ConnIDKey* key;
};
```

### 4.3 连接状态机

```cpp
// src/Conn.h — 连接状态定义

enum ConnectionState {
    STATE_INI,        // 初始状态
    STATE_SYN,         // SYN 发送
    STATE_SYN_ACK,    // SYN-ACK 接收
    STATE_ESTABLISHED, // 连接建立
    STATE_SYN_DONE,    // 半开连接（服务端）
    STATE_CLOSE,       // 关闭中
    STATE_CLOSED,      // 完全关闭
    STATE_OUT,         // 过期移除
};
```

### 4.4 会话超时

```zeek
# scripts/base/init.zeek — 超时配置

# 连接超时阈值
option tcp_inactivity_timeout = 5 min;
option udp_inactivity_timeout = 1 min;
option icmp_inactivity_timeout = 1 min;

# 半开连接超时（收到 SYN 未完成握手）
option tcp_connection_request_timeout = 1 min;

# 连接完成后的超时
option tcp_content_delivery_timeout = 30 sec;
```

---

## 5. Analyzer 框架

### 5.1 Analyzer 层次结构

Zeek 的协议分析采用 **Analyzer 层次结构**：

```
Analyzer (基类)
├── TransportLayerAnalyzer
│   ├── TCP_Analyzer
│   │   ├── HTTP_Analyzer
│   │   ├── SMB_Analyzer
│   │   ├── SSH_Analyzer
│   │   └── ...
│   ├── UDP_Analyzer
│   │   ├── DNS_Analyzer
│   │   ├── NTP_Analyzer
│   │   └── ...
│   └── ICMP_Analyzer
└── GenericAnalyzer (通用载荷分析)
```

### 5.2 Analyzer 基类

```cpp
// src/Analyzer.h

class Analyzer {
public:
    // 协议名称
    const char* name() const { return name_; }

    // 是否启用
    bool IsEnabled() const { return enabled; }

    // 转发数据包到分析器
    virtual void ForwardPacket(int len, const uint8_t* data, uint64_t seq,
                                 bool is_orig);

    // 协议确认（首次看到有效协议载荷）
    virtual void ProtocolConfirmation();

    // 协议否定（确定不是某协议）
    virtual void ProtocolViolation();

    // 构造函数
    Analyzer(Analyzer* arg_parent, const char* arg_name);

protected:
    const char* name_;
    Analyzer* parent_;        // 父分析器
    bool enabled_;            // 是否激活
    uint64_t identifier_;     // 分析器 ID
};

// TCP 分析器基类
class TCP_Analyzer : public TransportLayerAnalyzer {
public:
    TCP_Analyzer(Analyzer* parent, const char* name);

    virtual void DeliverSegment(int len, const uint8_t* data,
                                uint64_t seq, bool is_orig, bool has_SYN,
                                bool has_FIN, bool has_RST,
                                bool is_retransmit);

    virtual void EndOfData(bool is_orig);

    // 流重组器
    StreamReassembler* reassembler_;
};
```

### 5.3 HTTP Analyzer

```cpp
// src/analyzer/protocol/http/HTTP.h

class HTTP_Analyzer : public TCP_Analyzer {
public:
    HTTP_Analyzer(Connection* conn);

    virtual void DeliverSegment(int len, const uint8_t* data,
                                 uint64_t seq, bool is_orig,
                                 bool has_SYN, bool has_FIN, bool has_RST) override;

    // 状态机
    enum HTTPState {
        HTTP_INI,           // 初始
        HTTP_REQUEST_LINE,  // 读取请求行
        HTTP_HEADERS,       // 读取头部
        HTTP_BODY,          // 读取 body
        HTTP_RESPONSE_LINE, // 读取响应行
        HTTP_DONE           // 完成
    };

private:
    HTTPState state_;
    HTTPRequest* request_;
    HTTPResponse* response_;
    std::string version_;
};
```

### 5.4 Analyzer 注册

```cpp
// src/analyzer/Protocol.cc — 分析器注册

// 注册到全局表
void Analyzer::Register(const char* name, int id, Analyzer* analyzer) {
    analyzer_mgr->Add(name, id, analyzer);
}

// 端口到分析器的映射
// src/analyzer/Portmap.cc

void PortmapManager::Register(Analyzer* analyzer, TransportType transport,
                               uint16_t port, bool add_reversed = true) {
    // 添加到端口映射表
    port_map[transport][port] = analyzer;

    // 自动反向映射（目的端口 → 源端口）
    if ( add_reversed )
        port_map[transport][65535 - port] = analyzer;
}
```

**内置端口映射**：

```cpp
// 默认端口映射
{TCP, 80}   → HTTP_Analyzer
{TCP, 443}  → SSL_Analyzer
{TCP, 53}   → DNS_Analyzer
{TCP, 22}   → SSH_Analyzer
{TCP, 25}   → SMTP_Analyzer
{TCP, 445}  → SMB_Analyzer
{UDP, 53}   → DNS_Analyzer
{UDP, 123}  → NTP_Analyzer
```

---

## 6. ZeekScript 解释器

### 6.1 ZeekScript 特点

ZeekScript 是 Zeek 的定制脚本语言：

- **语法**：类似 C，但专为网络分析设计
- **类型系统**：强类型 + 自动类型推导
- **内置类型**：record、table、set、vector、opaque
- **执行模型**：事件驱动（event-driven）
- **解释执行**：由 C++ 解释器执行（无 JIT）

### 6.2 核心类型

```zeek
# ZeekScript 类型系统示例

# 基本类型
local x: int = 42;
local s: string = "hello";
local b: bool = T;
local a: addr = 192.168.1.1;
local p: port = 80/tcp;

# record 类型（类似 struct）
type ConnInfo: record {
    orig_h: addr;
    resp_h: addr;
    orig_p: port;
    resp_p: port;
    duration: interval;
};

# table / set / vector
local t: table[string] of int = table();
local s: set[addr] = set();
local v: vector of string = vector();

# 函数类型
type MyFunc: function(a: int, b: string): bool;
type MyHook: hook(a: connection): bool;
```

### 6.3 事件处理程序

```zeek
# 事件处理程序语法
event event_name(param1: type1, param2: type2) {
    # 处理逻辑
}

# 示例
event connection_established(c: connection) {
    print fmt("New connection: %s -> %s",
              c$id$orig_h, c$id$resp_h);
}

# 条件事件处理
event http_request(c: connection, method: string, URI: string, version: string) {
    if (method == "POST" && /password|passwd|secret/ in URI) {
        NOTICE([$note = Suspicious_HTTP,
                $conn = c,
                $msg = fmt("Suspicious URI: %s", URI)]);
    }
}
```

### 6.4 Hook（钩子）

Hook 是 ZeekScript 特有的多播处理机制：

```zeek
# Hook 语法
hook hook_name(params) {
    # 处理逻辑
}

# 定义 hook 类型
type MyHook: hook(c: connection, msg: string);

# 使用 hook
event zeek_init() {
    # 触发 hook（所有处理程序都会被调用）
    break hit MyHook(c, "hello");
}
```

**Hook vs Event**：

| 特性     | Event                | Hook                 |
| :------- | :------------------- | :------------------- |
| 调用方式 | 单播（一个处理程序） | 多播（所有处理程序） |
| 中断机制 | 无                   | `break` 可停止传播   |
| 返回值   | void                 | bool（可中断）       |
| 使用场景 | 日志记录、通知       | 预处理、验证         |

---

## 7. 协议分用（Demux）流程

### 7.1 分用决策树

```
数据包
  ↓
[IP Layer] — 判断 IPv4 / IPv6
  ↓
[Transport Layer] — 判断 TCP / UDP / ICMP
  ↓
[Port-based Heuristic] — 查询端口映射表
  ↓ 或
[Signature-based Detection] — 正则匹配协议特征
  ↓
[Analyzer::ProtocolConfirmation] — 确认协议
  ↓
[Forward to Analyzer] — 分用数据到分析器
  ↓
[App-layer Events] — 派发应用层事件
```

### 7.2 端口分用示例

```cpp
// src/analyzer/Portmap.cc — 端口映射

// HTTP 端口注册
new PortmapEntry(new TCP_Analyzer("HTTP", connection),
                80, true);   // add_reversed: 自动添加 65475 (65535-80)

// HTTPS 端口注册
new PortmapEntry(new SSL_Analyzer(connection),
                443, true);

// 自定义端口映射
redef TCP_port_analyses += {
    [$ports = set(8080/tcp, 8443/tcp), $analyser = HTTP_Analyzer()],
};
```

### 7.3 签名分用

```zeek
# scripts/policy/protocols/http/detect-webapps.zeek

# 签名定义
signature sig_http_useragent {
    ip-proto == tcp
    payload /.*Mozilla\/4\.0.*MSIE/
    enable "HTTP_Analyzer"
}

# 使用签名分用
@load policy/misc/detect-protocols
```

---

## 8. 集群架构（简述）

Zeek 集群通过 **Broker** 通信框架协调多节点：

```
┌─────────────────────────────────────────────┐
│              Manager Node                   │
│  ┌─────────┐  ┌─────────┐  ┌───────────┐   │
│  │ Manager │  │  Proxy  │  │ Logger    │   │
│  │ Process │  │ Process │  │ Process   │   │
│  └─────────┘  └─────────┘  └───────────┘   │
│        ↑            ↑            ↑         │
│        └────────────┼────────────────┘     │
│              Broker AMQP                    │
│              (TCP + TLS)                    │
├───────────────┼─────────────────┬──────────┤
│               │                 │          │
│        ┌──────┴─────┐    ┌──────┴─────┐   │
│        │  Worker-1  │    │  Worker-2  │   │
│        │  Process   │    │  Process   │   │
│        └───────────┘    └───────────┘   │
│               ↑             ↑           │
│         ┌─────┴───┐   ┌─────┴───┐      │
│         │eth0    │   │eth0    │       │
└─────────┴─────────┘   └─────────┘───────┘
```

详细集群架构见 [[2026-04-15-zeek-deep-dive-ch25-cluster-arch|Part V 集群部署]]。

---

## 9. 本章小结

本章深入解析了 Zeek 的核心架构：

1. **C++ 核心引擎**：PacketManager、事件引擎、会话管理
2. **事件驱动模型**：事件派发流程、事件队列、核心事件列表
3. **会话管理**：SessionMap、Connection 对象、连接状态机
4. **Analyzer 框架**：层次结构、TCP/UDP 分析器、端口映射、签名检测
5. **ZeekScript 解释器**：类型系统、事件处理程序、Hook 机制
6. **协议分用流程**：端口分用、签名分用、协议确认

**下一章**将深入解析 Zeek 的日志系统——ASCII/JSON/CSV 输出、Log Writer 框架、日志轮转。
