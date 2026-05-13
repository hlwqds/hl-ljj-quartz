---
title: "Zeek 深度探索 (二十五)：集群架构"
date: 2026-04-15
tags:
  - zeek
  - series
  - cluster
  - zeekcontrol
  - manager
  - proxy
  - worker
  - logger
description: "深入解析 Zeek 集群架构——manager/proxy/p logger/worker 角色定义、集群拓扑、ZeekControl 架构、进程间通信机制"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ...
> 24. [[2026-04-15-zeek-deep-dive-ch24-notice|第二十四章：Notice 框架]]
> 25. **第二十五章：集群架构**
> 26. [[2026-04-15-zeek-deep-dive-ch26-cluster-config|第二十六章：集群配置]]
> 27. [[2026-04-15-zeek-deep-dive-ch27-communication|第二十七章：通信]]
> 28. [[2026-04-15-zeek-deep-dive-ch28-load-balancing|第二十八章：负载均衡]]
> 29. [[2026-04-15-zeek-deep-dive-ch29-packet-loss|第二十九章：丢包处理]]

---

## 1. Zeek 集群概述

Zeek 集群是**分布式网络分析部署架构**，通过将分析负载分散到多个节点实现：
- **横向扩展**：增加 worker 节点提升吞吐量
- **高可用性**：单节点故障不影响整体分析
- **集中管理**：统一配置、日志收集、策略下发
- **流量分发**：多节点并行处理网络流量

### 1.1 单机 vs 集群

```
┌─────────────────────────────────────────────────────────────┐
│                     Zeek 单机模式                             │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐     │
│  │   Packet    │ → │   Event     │ → │   Analyzer  │     │
│  │   Source    │   │   Engine    │   │   Framework │     │
│  └─────────────┘   └─────────────┘   └─────────────┘     │
│                          ↓                                   │
│  ┌─────────────┐   ┌─────────────┐                         │
│  │    Log      │ ← │   ZeekScript │                         │
│  │   Writers   │   │   Runtime   │                         │
│  └─────────────┘   └─────────────┘                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                     Zeek 集群模式                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                    Manager Node                        │  │
│  │  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐ │  │
│  │  │   Config    │   │   Policy    │   │   Log       │ │  │
│  │  │   Manager   │   │   Scripts   │   │   Aggregator│ │  │
│  │  └─────────────┘   └─────────────┘   └─────────────┘ │  │
│  └──────────────────────────────────────────────────────┘  │
│           ↑                    ↑                    ↑       │
│  ┌────────┴────────┐  ┌───────┴───────┐  ┌────────┴─────┐  │
│  │     Proxy      │  │    Proxy      │  │    Proxy     │  │
│  │   (Frontend)   │  │   (Frontend)  │  │  (Frontend)  │  │
│  └────────┬────────┘  └───────┬──────┘  └────────┬─────┘  │
│           ↓                    ↓                    ↓       │
│  ┌────────┴────────┐  ┌───────┴───────┐  ┌────────┴─────┐  │
│  │     Worker      │  │    Worker     │  │    Worker    │  │
│  │  ┌───────────┐  │  │  ┌─────────┐  │  │  ┌────────┐  │  │
│  │  │  Capture  │  │  │  │ Capture │  │  │  │Capture│  │  │
│  │  │  Point    │  │  │  │ Point  │  │  │  │ Point │  │  │
│  │  └───────────┘  │  │  └─────────┘  │  │  └────────┘  │  │
│  └─────────────────┘  └───────────────┘  └──────────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 集群角色

| 角色 | 功能 | 数量 | 资源需求 |
|:---|:---|:---|:---|
| **Manager** | 集群协调、配置管理、日志聚合 | 1 | 高 CPU/内存 |
| **Proxy** | 前端代理、流量分发、状态同步 | 2+ | 中等 |
| **Worker** | 数据包捕获、协议分析、事件生成 | N | 高网络/CPU |
| **Logger** | 日志写入、持久化 | 1+ | 高磁盘 I/O |

---

## 2. Manager 节点

Manager 是集群的**控制平面**，负责协调整个集群的运行。

### 2.1 Manager 职责

```
┌─────────────────────────────────────────────┐
│              Manager 职责                    │
├─────────────────────────────────────────────┤
│                                             │
│  1. 配置管理                                 │
│     - 加载 zeekctl 配置                       │
│     - 分发节点配置到各组件                      │
│     - 管理 cluster-layout.zeek                │
│                                             │
│  2. 进程管理                                 │
│     - 启动/停止/监控各节点进程                  │
│     - 处理节点故障恢复                         │
│     - 收集节点状态                            │
│                                             │
│  3. 日志聚合                                 │
│     - 接收来自 proxy 的日志流                  │
│     - 合并、排序、去重                         │
│     - 输出到最终日志文件                       │
│                                             │
│  4. 策略协调                                 │
│     - 同步策略脚本到所有节点                    │
│     - 维护全局状态表                          │
│                                             │
└─────────────────────────────────────────────┘
```

### 2.2 Manager 源码结构

```cpp
// zeek/cluster/Cluster.h — Manager 相关结构
namespace zeek::cluster {

// Manager 状态
enum class ManagerState {
    INITIALIZING,    // 初始化
    RUNNING,         // 运行中
    SHUTTING_DOWN,   // 关闭中
    TERMINATED       // 已终止
};

// Manager 配置
struct ManagerConfig {
    // 监听地址
    std::string listen_address;
    uint16_t listen_port;

    // 日志聚合
    std::string log_dir;
    size_t max_log_buffer_size;

    // 节点超时
    uint32_t node_timeout_sec;

    // 通信
    std::string protocol;  // "broker" | "zeekcontrol"
};

// Manager 主类
class Manager {
public:
    Manager();
    ~Manager();

    // 初始化
    void Init(const ManagerConfig& config);

    // 节点管理
    void RegisterNode(NodeType type, const std::string& id);
    void UnregisterNode(const std::string& id);
    bool IsNodeAlive(const std::string& id);

    // 日志聚合
    void EnqueueLog(const LogRecord& log);
    void FlushLogs();

    // 消息处理
    void DispatchMessage(const Message& msg);

private:
    ManagerConfig config;
    ManagerState state;

    // 节点表
    std::map<std::string, NodeStatus> nodes;

    // 日志缓冲区
    std::vector<LogRecord> log_buffer;
    std::mutex log_mutex;

    // Broker 通信
    BrokerComm* broker_comm;
};

} // namespace zeek::cluster
```

### 2.3 Manager 启动流程

```cpp
// zeek/cluster/Cluster.cc — Manager 启动
void Cluster::Manager::Start()
    {
    // 1. 加载集群配置
    LoadClusterLayout();

    // 2. 初始化 Broker 通信
    broker_comm = new BrokerComm();
    broker_comm->Listen(config.listen_address, config.listen_port);

    // 3. 注册日志写入器
    log_manager = new LogManager(config.log_dir);

    // 4. 启动节点监控
    StartNodeMonitor();

    // 5. 进入主循环
    while (state != ManagerState::SHUTTING_DOWN) {
        // 处理Broker消息
        ProcessBrokerMessages();

        // 检查节点心跳
        CheckNodeHealth();

        // 刷新日志缓冲区
        if (ShouldFlushLogs())
            FlushLogs();

        // 处理定时器
        ProcessTimers();

        std::this_thread::sleep_for(10ms);
    }

    // 优雅关闭
    Shutdown();
    }
```

---

## 3. Proxy 节点

Proxy 是**前端代理节点**，位于 Manager 和 Worker 之间，承担流量分发和状态聚合功能。

### 3.1 Proxy 职责

```
┌─────────────────────────────────────────────┐
│              Proxy 职责                      │
├─────────────────────────────────────────────┤
│                                             │
│  1. 流量分发                                 │
│     - 接收来自 worker 的事件                  │
│     - 负载均衡到 manager                      │
│     - 支持 Round-Robin / Hash 分发            │
│                                             │
│  2. 状态缓存                                 │
│     - 缓存高频访问的连接状态                   │
│     - 减少 manager 查询压力                   │
│                                             │
│  3. 日志中转                                 │
│     - 收集 worker 日志                        │
│     - 预处理、过滤、聚合                       │
│     - 发送到 manager                          │
│                                             │
│  4. 事件路由                                 │
│     - 根据事件类型路由到不同处理管道            │
│     - 支持事件优先级                          │
│                                             │
└─────────────────────────────────────────────┘
```

### 3.2 Proxy 架构

```cpp
// zeek/cluster/Proxy.h — Proxy 核心结构

// Proxy 类型
enum class ProxyType {
    FRONTEND,     // 前端代理：接收 worker 事件
    BACKEND,      // 后端代理：连接到 manager
    BIDIRECTIONAL // 双向代理
};

// Proxy 配置
struct ProxyConfig {
    ProxyType type;

    // 上游连接（连接到 manager 或其他 proxy）
    std::vector<BrokerEndpoint> upstream_endpoints;

    // 下游监听
    std::string listen_address;
    uint16_t listen_port;

    // 负载均衡策略
    LoadBalancingStrategy lb_strategy;
    uint32_t lb_hash_fields;  // hash fields mask

    // 缓冲配置
    size_t send_buffer_size;
    uint32_t flush_interval_ms;
};

// Proxy 主类
class Proxy {
public:
    Proxy(const ProxyConfig& config);
    ~Proxy();

    // 连接管理
    void ConnectToUpstream(const BrokerEndpoint& ep);
    void AcceptDownstream();

    // 事件处理
    void EnqueueEvent(const Event& event);
    void ForwardEvent(const Event& event);

    // 状态同步
    void SyncState(const StateUpdate& update);

private:
    ProxyConfig config;

    // 上游连接
    std::vector<std::shared_ptr<BrokerPeer>> upstream_peers;
    std::mutex upstream_mutex;

    // 下游连接
    std::vector<std::shared_ptr<BrokerPeer>> downstream_peers;

    // 事件队列
    std::queue<Event> event_queue;
    std::mutex queue_mutex;

    // 统计
    uint64_t events_forwarded;
    uint64_t bytes_sent;
};
```

### 3.3 Proxy 事件转发

```cpp
// zeek/cluster/Proxy.cc — 事件转发逻辑

void Proxy::ForwardEvent(const Event& event)
    {
    // 1. 根据类型判断路由
    if (IsHighPriorityEvent(event.type)) {
        // 高优先级事件直接转发
        SendToUpstream(event);
    } else {
        // 普通事件进入队列
        EnqueueEvent(event);
    }

    // 2. 更新统计
    UpdateStats(event);

    // 3. 检查是否需要刷新
    if (ShouldFlush())
        FlushQueue();
    }

// 负载均衡选择上游节点
std::shared_ptr<BrokerPeer> Proxy::SelectUpstreamPeer(const Event& event)
    {
    switch (config.lb_strategy) {
    case LoadBalancingStrategy::ROUND_ROBIN:
        return SelectRoundRobin();
    case LoadBalancingStrategy::_HASH:
        return SelectByHash(event);
    case LoadBalancingStrategy::LEAST_LOADED:
        return SelectLeastLoaded();
    default:
        return upstream_peers[0];
    }
    }

// Hash 负载均衡
std::shared_ptr<BrokerPeer> Proxy::SelectByHash(const Event& event)
    {
    // 根据连接 ID 或其他字段计算 hash
    uint32_t hash = 0;
    if (event.HasConnectionID()) {
        const auto& cid = event.GetConnectionID();
        hash = Hash5Tuple(cid.orig_h, cid.orig_p,
                          cid.resp_h, cid.resp_p, cid.proto);
    } else {
        hash = std::hash<std::string>{}(event.type);
    }

    // 一致性 Hash 环查找
    size_t idx = hash % upstream_peers.size();
    return upstream_peers[idx];
    }
```

---

## 4. Worker 节点

Worker 是**实际分析节点**，负责抓包和协议分析。

### 4.1 Worker 职责

```
┌─────────────────────────────────────────────┐
│              Worker 职责                      │
├─────────────────────────────────────────────┤
│                                             │
│  1. 数据包捕获                                │
│     - 从网络接口抓取数据包                     │
│     - 支持 libpcap / PF_RING / AF_XDP        │
│     - 数据包分片重组                          │
│                                             │
│  2. 协议分析                                 │
│     - TCP/UDP 会话跟踪                       │
│     - 应用层协议解析（HTTP/DNS/TLS/...）       │
│     - 生成协议事件                            │
│                                             │
│  3. 事件生成                                 │
│     - 生成 connection_event                   │
│     - 生成协议特定事件                        │
│     - 生成文件分析事件                        │
│                                             │
│  4. 状态管理                                 │
│     - 维护本地连接表                          │
│     - 状态超时处理                            │
│     - 与 proxy 同步关键状态                   │
│                                             │
│  5. 日志本地缓存                              │
│     - 本地日志缓冲                            │
│     - 批量发送到 proxy                        │
│                                             │
└─────────────────────────────────────────────┘
```

### 4.2 Worker 源码结构

```cpp
// zeek/cluster/Worker.h — Worker 核心结构

// Worker 配置
struct WorkerConfig {
    // 节点标识
    std::string node_name;
    std::string cluster_name;

    // 捕获配置
    std::string interface;           // 网络接口
    std::string pkt_source_type;     // libpcap | pf_ring | af_xdp
    std::map<std::string, std::string> pkt_source_options;

    // 分析配置
    std::vector<std::string> loaded_scripts;
    std::vector<std::string> disabled_analyzers;

    // 通信配置
    BrokerEndpoint proxy_endpoint;
    uint32_t heartbeat_interval_sec;

    // 资源限制
    size_t max_memory_bytes;
    uint32_t max_concurrent_connections;
};

// Worker 主类
class Worker {
public:
    Worker(const WorkerConfig& config);
    ~Worker();

    // 启动/停止
    void Start();
    void Stop();

    // 抓包主循环
    void CaptureLoop();

    // 事件处理
    void ProcessEvent(const Event& event);

    // 日志发送
    void SendLogs();

    // 心跳
    void SendHeartbeat();

private:
    WorkerConfig config;

    // 抓包源
    iosource::PktSrc* pkt_src;

    // 分析引擎
    event_engine::Engine* event_engine;

    // 会话管理
    SessionMap* session_map;

    // 日志缓冲
    std::vector<LogRecord> log_buffer;
    size_t log_buffer_size;

    // Broker 通信
    BrokerComm* broker_comm;

    // 统计
    uint64_t pkts_captured;
    uint64_t bytes_captured;
    uint64_t events_generated;
};
```

### 4.3 Worker 抓包循环

```cpp
// zeek/cluster/Worker.cc — Worker 主循环

void Worker::CaptureLoop()
    {
    while (! ShouldStop()) {
        // 1. 等待数据包
        Packet* pkt = pkt_src->WaitForPacket();

        if (! pkt) {
            // 超时或其他错误
            continue;
        }

        // 2. 处理数据包
        try {
            // 分用协议
            event_engine->ProcessPacket(pkt);

            // 3. 生成事件
            DispatchEvents();

            // 4. 更新统计
            UpdateCaptureStats(pkt);

        } catch (const std::exception& e) {
            // 记录错误
            Reporter::Error("Packet processing error: %s", e.what());
        }

        // 5. 定期发送日志和心跳
        if (ShouldFlushLogs())
            SendLogs();

        if (ShouldSendHeartbeat())
            SendHeartbeat();

        // 6. 检查资源限制
        CheckResourceLimits();
    }

    // 优雅关闭
    DrainAndShutdown();
    }
```

---

## 5. Logger 节点

Logger 专门负责日志的持久化存储。

### 5.1 Logger 职责

```
┌─────────────────────────────────────────────┐
│              Logger 职责                      │
├─────────────────────────────────────────────┤
│                                             │
│  1. 日志写入                                 │
│     - 接收来自 manager 的日志流               │
│     - 写入 ASCII / JSON / CBOR 格式          │
│     - 支持多种输出后端                        │
│                                             │
│  2. 日志轮转                                 │
│     - 基于时间轮转（每小时/每天）              │
│     - 基于大小轮转                            │
│     - 压缩旧日志                            │
│                                             │
│  3. 日志过滤                                 │
│     - 基于类型过滤                            │
│     - 基于字段过滤                            │
│     - 敏感信息脱敏                            │
│                                             │
│  4. 日志索引                                 │
│     - 创建日志索引                           │
│     - 支持快速查询                           │
│                                             │
└─────────────────────────────────────────────┘
```

### 5.2 Logger 配置

```cpp
// zeek/cluster/Logger.h — Logger 核心结构

struct LoggerConfig {
    // 输出配置
    std::string output_dir;
    LogFormat log_format;  // ASCII | JSON | CBOR

    // 轮转配置
    RotationPolicy rotation_policy;
    uint64_t rotation_size;      // bytes
    uint64_t rotation_interval;  // seconds

    // 过滤配置
    std::vector<LogFilter> filters;

    // 管道配置
    bool enable_pipeline;
    uint32_t pipeline_size;

    // 后端配置
    LogBackend backend;  // FILE |滚动写入|
    std::string backend_options;
};

// Logger 主类
class Logger {
public:
    Logger(const LoggerConfig& config);
    ~Logger();

    void Start();
    void Stop();

    // 日志处理
    void WriteLog(const LogRecord& record);
    void WriteBatch(const std::vector<LogRecord>& records);

    // 轮转
    void Rotate();
    void ProcessRotation();

private:
    LoggerConfig config;

    // 输出文件
    std::unique_ptr<OutputFile> current_file;
    std::string current_path;

    // 缓冲
    std::vector<LogRecord> write_buffer;
    std::mutex buffer_mutex;

    // 统计
    uint64_t logs_written;
    uint64_t bytes_written;
    uint64_t rotations;
};
```

---

## 6. 集群拓扑

### 6.1 典型拓扑

```
                            ┌─────────────┐
                            │   Manager   │
                            │  (Control)  │
                            └──────┬──────┘
                                   │
               ┌───────────────────┼───────────────────┐
               │                   │                   │
        ┌──────┴──────┐     ┌──────┴──────┐     ┌──────┴──────┐
        │   Proxy 1   │     │   Proxy 2   │     │   Proxy 3   │
        │  (Frontend) │     │  (Frontend) │     │  (Frontend) │
        └──────┬──────┘     └──────┬──────┘     └──────┬──────┘
               │                   │                   │
    ┌──────────┼──────────┐ ┌──────┼──────┐ ┌─────────┼─────────┐
    │          │          │ │      │      │ │         │         │
┌───┴───┐ ┌───┴───┐ ┌───┴───┐ ┌───┴───┐ ┌─┴───┐ ┌───┴───┐ ┌───┴───┐
│Worker1│ │Worker2│ │Worker3│ │Worker4│ │Wor- │ │Wor-  │ │Wor-  │
│      │ │      │ │      │ │      │ │ker5 │ │ker6 │ │ker7  │
└───────┘ └───────┘ └───────┘ └───────┘ └─────┘ └───────┘ └───────┘

       ↑                    ↑                    ↑
   Interface 1         Interface 2           Interface 3
   (10G SPAN)         (10G SPAN)           (10G SPAN)
```

### 6.2 角色组合

在小型部署中，可以组合角色：

| 部署规模 | 节点配置 |
|:---|:---|
| **单机** | Manager + Proxy + Logger + Worker（全部组合） |
| **小规模** | Manager + Logger + Worker<br/>Proxy 独立 |
| **中规模** | Manager 独立<br/>Proxy x 2（HA）<br/>Logger x 2（HA）<br/>Worker x N |
| **大规模** | Manager Cluster（HA）<br/>Proxy x 4+<br/>Logger Cluster<br/>Worker x 16+ |

### 6.3 通信路径

```
Worker → Proxy → Manager
   │         │
   │         └──→ Logger
   │
   └──→ Logger (本地写入)

Manager → Proxy → Worker (控制命令)
   ↑
   │
   └───────── Broker Mesh (状态同步)
```

---

## 7. ZeekControl 架构

ZeekControl 是 Zeek 的**集群管理框架**，提供命令行和配置接口。

### 7.1 ZeekControl 组件

```
┌─────────────────────────────────────────────────────────────┐
│                    ZeekControl 架构                           │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                    zeekctl CLI                           ││
│  │  (命令行管理工具)                                          ││
│  └─────────────────────────────────────────────────────────┘│
│                            ↓                                 │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                  Cluster Manager                         ││
│  │  - 节点状态监控                                           ││
│  │  - 配置分发                                               ││
│  │  - 日志收集                                               ││
│  │  - 进程管理                                               ││
│  └─────────────────────────────────────────────────────────┘│
│                            ↓                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │  Broker  │  │  Broker  │  │  Broker  │  │  Broker  │  │
│  │  (Mgr)   │  │  (Proxy) │  │  (Proxy) │  │  (Worker)│  │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 ZeekControl 脚本结构

```zeek
# zeek/scripts/zeekctl/cluster.zeek — 集群管理脚本

module ZeekControl;

export {
    # 全局状态
    global cluster_state: table[string] of NodeState;

    # 节点配置
    global node_config: table[string] of NodeConfig;

    # 连接状态
    global connections: table[string] of Broker::Peer;
}

# 节点状态
type NodeState: enum {
    STATE_INIT,
    STATE_STARTING,
    STATE_RUNNING,
    STATE_STOPPING,
    STATE_FAILED
};

# 节点配置
type NodeConfig: record {
    id: string;
    type: string;  # manager | proxy | worker | logger
    host: string;
    port: count;
    interface: string &optional;
    scripts: vector of string;
};
```

### 7.3 节点发现机制

```zeek
# zeek/scripts/zeekctl/node-discovery.zeek — 节点发现

event Broker::peer_added(node: Broker::EndpointInfo, msg: string)
    {
    local id = node$id;

    print fmt("Node joined: %s", id);

    # 更新节点状态
    cluster_state[id] = STATE_RUNNING;

    # 发送节点配置
    if (node$type == PEER_TYPE_WORKER) {
        SendNodeConfig(id, node_config[id]);
    }
    }

event Broker::peer_lost(node: Broker::EndpointInfo, msg: string)
    {
    local id = node$id;

    print fmt("Node left: %s", id);

    # 更新节点状态
    cluster_state[id] = STATE_FAILED;

    # 尝试重新连接
    if (node_config[id]$type == "worker") {
        schedule 5sec { Broker::retry_connect(node$network$address,
                                              node$network$port) };
    }
    }
```

---

## 8. Broker 通信框架

Broker 是 Zeek 集群的**消息通信层**，基于 CAF（C++ Actor Framework）实现。

### 8.1 Broker 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Broker 架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐       │
│  │   Topic     │   │   Data      │   │   Peer      │       │
│  │   Store     │   │   Store     │   │   Discovery │       │
│  └─────────────┘   └─────────────┘   └─────────────┘       │
│          ↓               ↓               ↓                  │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    Message Bus                           │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │ │
│  │  │  Pub/Sub │  │  RPC     │  │  Status  │             │ │
│  │  └──────────┘  └──────────┘  └──────────┘             │ │
│  └────────────────────────────────────────────────────────┘ │
│          ↓               ↓               ↓                  │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐       │
│  │   TCP/UDP   │   │   WebSocket │   │   ZeroMQ    │       │
│  │   (Native)  │   │   (HTTP)    │   │   (Compat)  │       │
│  └─────────────┘   └─────────────┘   └─────────────┘       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 8.2 Broker 消息类型

```cpp
// zeek/broker/Message.h — Broker 消息类型

namespace zeek::broker {

// 消息类型枚举
enum class MessageType : uint8_t {
    // 控制消息
    PEER_REGISTRATION,      // 节点注册
    PEER_UNREGISTRATION,   // 节点注销
    HEARTBEAT,             // 心跳
    SHUTDOWN,              // 关闭命令

    // 数据消息
    CONNECTION_EVENT,       // 连接事件
    LOG_RECORD,            // 日志记录
    STATE_UPDATE,          // 状态更新
    FILE_EVENT,            // 文件事件

    // 查询消息
    STATUS_QUERY,          // 状态查询
    STATUS_RESPONSE,      // 状态响应
    CONFIG_QUERY,          // 配置查询
    CONFIG_RESPONSE,      // 配置响应
};

// 消息基类
struct Message {
    MessageType type;
    std::string sender_id;
    uint64_t timestamp;
    std::vector<uint8_t> payload;
};

// 连接事件消息
struct ConnectionEventMsg : Message {
    ConnectionID conn_id;
    std::string event_name;
    std::vector<Val*> event_args;
};

// 日志消息
struct LogRecordMsg : Message {
    std::string stream;
    LogWriter::Info writer_info;
    std::string log_line;
};

// 状态更新消息
struct StateUpdateMsg : Message {
    std::string state_type;
    std::string key;
    Value old_value;
    Value new_value;
};

} // namespace zeek::broker
```

### 8.3 Broker 发布订阅

```cpp
// zeek/broker/Comm.cc — Broker 通信实现

// 发布消息
void BrokerComm::Publish(const std::string& topic, const broker::Data& data)
    {
    auto msg = broker::message{topic, data};
    endpoint.publish(msg);
    stats.published++;
    }

// 订阅主题
void BrokerComm::Subscribe(const std::string& topic,
                          std::function<void(const broker::message&)> handler)
    {
    endpoint.subscribe(topic, [handler](const broker::message& msg) {
        handler(msg);
        stats.messages_received++;
    });

    subscribed_topics.insert(topic);
    }

// RPC 调用
broker::expected<broker::data>
BrokerComm::Call(const broker::endpoint& remote,
                const std::string& topic,
                const broker::data& request,
                std::chrono::milliseconds timeout)
    {
    auto future = endpoint.make_call(remote, topic, request);
    auto result = future.get(timeout);

    if (result)
        stats.successful_calls++;
    else
        stats.failed_calls++;

    return result;
    }
```

---

## 9. 集群高可用性

### 9.1 故障检测

```cpp
// zeek/cluster/HighAvailability.h — HA 故障检测

class FailureDetector {
public:
    FailureDetector(uint32_t heartbeat_interval_sec,
                   uint32_t threshold_count);

    // 记录心跳
    void RecordHeartbeat(const std::string& node_id);

    // 检查节点是否存活
    bool IsNodeAlive(const std::string& node_id);

    // 获取死亡节点列表
    std::vector<std::string> GetDeadNodes();

private:
    uint32_t heartbeat_interval_sec;
    uint32_t threshold_count;

    std::map<std::string, uint64_t> last_heartbeat;
    std::map<std::string, uint32_t> missed_heartbeats;
    std::mutex mutex;
};

bool FailureDetector::IsNodeAlive(const std::string& node_id)
    {
    std::lock_guard<std::mutex> lock(mutex);

    auto now = std::chrono::steady_clock::now();
    auto last = last_heartbeat[node_id];

    auto elapsed = std::chrono::duration_cast<std::chrono::seconds>(
        now - last).count();

    return elapsed < (heartbeat_interval_sec * threshold_count);
    }
```

### 9.2 自动故障转移

```
┌─────────────────────────────────────────────────────────────┐
│                    故障转移流程                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  1. 故障检测                                                 │
│     Worker 停止发送心跳                                        │
│     Proxy 检测到连接断开                                       │
│           ↓                                                  │
│  2. 状态标记                                                 │
│     Manager 标记 Worker 为 FAILED                            │
│     重新分配流量                                              │
│           ↓                                                  │
│  3. 恢复处理                                                 │
│     等待 Worker 重新连接                                      │
│     或启动新的 Worker 替代                                    │
│           ↓                                                  │
│  4. 状态同步                                                 │
│     新 Worker 请求状态同步                                    │
│     补齐丢失的连接数据                                        │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 10. 总结

本章介绍了 Zeek 集群的核心架构：

| 组件 | 职责 | 关键源码 |
|:---|:---|:---|
| **Manager** | 控制平面、配置管理、日志聚合 | `zeek/cluster/Cluster.cc` |
| **Proxy** | 流量分发、状态缓存、负载均衡 | `zeek/cluster/Proxy.cc` |
| **Worker** | 数据包捕获、协议分析、事件生成 | `zeek/cluster/Worker.cc` |
| **Logger** | 日志持久化、轮转、过滤 | `zeek/cluster/Logger.cc` |
| **Broker** | 消息通信、发布订阅、RPC | `zeek/broker/Comm.cc` |

下一章我们将深入讨论**集群配置**，包括 `node.cfg`、`cluster-layout.zeek` 等配置文件的详细说明。

---

> [!previous] 上一章：[[2026-04-15-zeek-deep-dive-ch24-notice|第二十四章：Notice 框架]]
> [!next] 下一章：[[2026-04-15-zeek-deep-dive-ch26-cluster-config|第二十六章：集群配置]]
