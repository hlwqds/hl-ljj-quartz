---
title: "Zeek 深度探索 (二十七)：集群通信"
date: 2026-04-15
tags:
  - zeek
  - series
  - cluster
  - broker
  - zeekcontrol
  - communication
  - pubsub
  - rpc
description: "深入解析 Zeek 集群通信——ZeekControl 协议、Broker 通信框架、发布订阅、RPC 调用、消息序列化"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ... 25. [[2026-04-15-zeek-deep-dive-ch25-cluster-arch|第二十五章：集群架构]] 26. [[2026-04-15-zeek-deep-dive-ch26-cluster-config|第二十六章：集群配置]] 27. **第二十七章：通信** 28. [[2026-04-15-zeek-deep-dive-ch28-load-balancing|第二十八章：负载均衡]] 29. [[2026-04-15-zeek-deep-dive-ch29-packet-loss|第二十九章：丢包处理]]

---

## 1. 集群通信概述

Zeek 集群使用 **Broker** 作为统一的通信中间件，实现节点间的高效消息传递。

```
┌─────────────────────────────────────────────────────────────┐
│                    集群通信架构                              │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    Pub/Sub    ┌─────────────┐              │
│  │   Worker    │ ────────────→ │   Proxy     │              │
│  │  (Events)   │               │  (Events)   │              │
│  └─────────────┘               └──────┬──────┘              │
│                                        │                     │
│                               RPC      │                     │
│                                        ↓                     │
│  ┌─────────────┐    Status    ┌─────────────┐              │
│  │   Manager   │ ←───────────→ │   Proxy     │              │
│  │  (Control)  │               │  (Control)  │              │
│  └──────┬──────┘               └─────────────┘              │
│         │                                                      │
│         │ Data Store                                           │
│         ↓                                                      │
│  ┌─────────────┐                                             │
│  │   Logger    │                                             │
│  │   (Logs)    │                                             │
│  └─────────────┘                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 通信模式

| 模式          | 用途       | 示例                          |
| :------------ | :--------- | :---------------------------- |
| **发布/订阅** | 事件广播   | Worker 发布事件，Manager 订阅 |
| **RPC**       | 请求/响应  | Manager 查询节点状态          |
| **数据存储**  | 键值对共享 | 同步连接表、配置              |
| **点对点**    | 直接消息   | 节点间直接通信                |

---

## 2. Broker 框架

Broker 是 Zeek 基于 CAF（C++ Actor Framework）构建的**分布式通信库**。

### 2.1 Broker 架构

```
┌─────────────────────────────────────────────────────────────┐
│                      Broker 架构                            │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                   Broker Endpoint                      │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │ │
│  │  │  Topic   │  │   Data   │  │   Peer   │             │ │
│  │  │  Store   │  │  Store   │  │ Discovery│             │ │
│  │  └──────────┘  └──────────┘  └──────────┘             │ │
│  └────────────────────────────────────────────────────────┘ │
│                            ↓                                 │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                    Message Router                       │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │ │
│  │  │  Pub/Sub │  │   RPC    │  │  Status  │             │ │
│  │  └──────────┘  └──────────┘  └──────────┘             │ │
│  └────────────────────────────────────────────────────────┘ │
│                            ↓                                 │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                  Network Transport                      │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐             │ │
│  │  │   TCP    │  │  WebSocket│  │  ZeroMQ  │             │ │
│  │  └──────────┘  └──────────┘  └──────────┘             │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Broker 源码结构

```cpp
// zeek/broker/ — Broker 源码结构

zeek/broker/
├── Manager.h/.cc              # Broker 管理器
├── Comm.h/.cc                 # 通信接口
├── Data.h/.cc                 # 数据类型
├── Store.h/.cc                # 数据存储
├── Peer.h/.cc                 # 节点管理
├── Message.h/.cc               # 消息封装
├── Status.h/.cc                # 状态报告
└── Sub.h/.cc                  # 订阅管理
```

### 2.3 Broker 初始化

```cpp
// zeek/broker/Manager.cc — Broker 初始化

Broker::Manager::Manager()
    {
    // 1. 创建 Endpoint
    endpoint = std::make_unique<broker::endpoint>(
        "zeek-cluster",
        std::make_unique<broker::subscriber_factory>());

    // 2. 配置网络
    endpoint->listen(broker::network_address{
        config.bind_address,
        config.port});

    // 3. 初始化子系统
    status_subscriber = endpoint->make_status_subscriber(
        broker::subscription::forwarding);
    peer_status_subscriber = endpoint->make_peer_status_subscriber(
        broker::subscription::forwarding);

    // 4. 启动内部线程
    thread = std::thread(&Broker::Manager::Run, this);
    }

void Broker::Manager::Run()
    {
    while (running) {
        // 处理状态消息
        ProcessStatusUpdates();

        // 处理对端状态
        ProcessPeerStatusUpdates();

        std::this_thread::sleep_for(10ms);
    }
    }
```

---

## 3. 发布/订阅模式

### 3.1 主题定义

```cpp
// zeek/broker/Topic.h — 主题定义

namespace broker {

// 预定义主题
constexpr string_view topic_prefix = "zeek/";

constexpr string_view events_topic = "zeek/events";
constexpr string_view logs_topic = "zeek/logs";
constexpr string_view status_topic = "zeek/status";
constexpr string_view config_topic = "zeek/config";
constexpr string_view state_topic = "zeek/state";

// 事件主题格式
inline std::string MakeEventTopic(const std::string& event_name)
    {
    return fmt("%s/event/%s", topic_prefix, event_name);
    }

// 连接事件主题
inline std::string MakeConnectionTopic(const ConnectionID& cid)
    {
    return fmt("%s/conn/%" PRIu32 ".%" PRIu16,
               topic_prefix, cid.orig_h, cid.orig_p);
    }

} // namespace broker
```

### 3.2 发布消息

```cpp
// zeek/broker/Comm.cc — 发布消息

void BrokerComm::Publish(const std::string& topic,
                        std::vector<broker::data> args)
    {
    // 1. 构造消息
    auto msg = broker::message{topic, std::move(args)};

    // 2. 发布
    endpoint.publish(msg);

    // 3. 更新统计
    ++stats.published;
    stats.bytes_sent += EstimateSize(msg);
    }

// 发布连接事件
void BrokerComm::PublishConnectionEvent(const Connection& conn,
                                        const std::string& event_name)
    {
    auto topic = broker::MakeConnectionTopic(conn.id);

    auto msg = broker::message{
        topic,
        broker::data{conn.id.orig_h},
        broker::data{conn.id.orig_p},
        broker::data{conn.id.resp_h},
        broker::data{conn.id.resp_p},
        broker::data{conn.id.proto},
        broker::data{event_name}
    };

    endpoint.publish(msg);
    }
```

### 3.3 订阅消息

```cpp
// zeek/broker/Comm.cc — 订阅消息

// 订阅主题
void BrokerComm::Subscribe(const std::string& topic,
                          std::function<void(const broker::message&)> handler)
    {
    // 1. 创建订阅者
    auto sub = endpoint.subscribe(topic);

    // 2. 注册处理器
    std::lock_guard<std::mutex> lock(subscriptions_mutex);
    subscriptions[topic] = std::move(handler);

    // 3. 添加到事件循环
    auto loop = reinterpret_cast<uv_loop_t*>(
        event_loop->GetUVLoop());
    sub.attach_to(loop, [this, topic](const broker::message& msg) {
        auto it = subscriptions.find(topic);
        if (it != subscriptions.end()) {
            it->second(msg);
        }
    });
    }

// 订阅连接事件
void BrokerComm::SubscribeConnectionEvents(
    std::function<void(const ConnectionID&, const std::string&)> handler)
    {
    auto sub = endpoint.subscribe(broker::events_topic);

    auto wrapped_handler = [handler](const broker::message& msg) {
        if (msg.size() >= 6 &&
            msg.match_element<0>() == broker::data::type::string &&
            std::get<std::string>(msg[0]).find("conn/") == 0) {

            ConnectionID cid;
            cid.orig_h = broker::get<broker::address>(msg[1]);
            cid.orig_p = broker::get<broker::port>(msg[2]);
            cid.resp_h = broker::get<broker::address>(msg[3]);
            cid.resp_p = broker::get<broker::port>(msg[4]);
            std::string event_name = broker::get<std::string>(msg[6]);

            handler(cid, event_name);
        }
    };

    sub.attach_to(event_loop->GetUVLoop(), wrapped_handler);
    }
```

---

## 4. RPC 调用

### 4.1 RPC 消息类型

```cpp
// zeek/broker/RPC.h — RPC 定义

namespace broker {

// RPC 请求
struct RPCRequest {
    std::string id;              // 请求 ID
    std::string method;          // 方法名
    std::vector<data> args;      // 参数
    std::chrono::steady_clock::time_point sent_time;
};

// RPC 响应
struct RPCResponse {
    std::string id;              // 请求 ID
    std::variant<data, error> result;  // 结果或错误
    std::chrono::steady_clock::time_point recv_time;
};

// RPC 状态
enum class RPCState {
    PENDING,     // 等待中
    COMPLETED,   // 已完成
    TIMEOUT,     // 超时
    ERROR        // 错误
};

} // namespace broker
```

### 4.2 发起 RPC 调用

```cpp
// zeek/broker/Comm.cc — RPC 调用

// 发起异步 RPC 调用
std::future<broker::data>
BrokerComm::Call(const std::string& peer,
                const std::string& method,
                std::vector<broker::data> args,
                std::chrono::milliseconds timeout)
    {
    // 1. 生成请求 ID
    std::string request_id = GenerateUUID();

    // 2. 构造请求消息
    broker::message msg{
        "zeek/rpc/request",
        broker::data{request_id},
        broker::data{method},
        broker::data{std::move(args)}
    };

    // 3. 发送请求
    endpoint.publish(peer, msg);

    // 4. 创建 Future
    auto promise = std::make_shared<std::promise<broker::data>>();
    auto future = promise->get_future();

    // 5. 注册回调
    {
        std::lock_guard<std::mutex> lock(rpc_mutex);
        RPCPending request;
        request.promise = promise;
        request.timeout = std::chrono::steady_clock::now() + timeout;
        rpc_pending[request_id] = std::move(request);
    }

    return future;
    }

// 处理 RPC 响应
void BrokerComm::HandleRPCResponse(const broker::message& msg)
    {
    if (msg.size() < 3)
        return;

    auto request_id = broker::get<std::string>(msg[1]);
    auto result = msg[2];

    std::lock_guard<std::mutex> lock(rpc_mutex);
    auto it = rpc_pending.find(request_id);
    if (it != rpc_pending.end()) {
        it->second.promise->set_value(result);
        rpc_pending.erase(it);
    }
    }
```

### 4.3 注册 RPC 处理器

```cpp
// zeek/broker/Comm.cc — 注册 RPC 处理器

void BrokerComm::RegisterRPCHandler(
    const std::string& method,
    std::function<broker::data(std::vector<broker::data>)> handler)
    {
    std::lock_guard<std::mutex> lock(rpc_handlers_mutex);
    rpc_handlers[method] = std::move(handler);
    }

// 处理传入的 RPC 请求
void BrokerComm::HandleRPCRequest(const broker::message& msg)
    {
    if (msg.size() < 3)
        return;

    auto request_id = broker::get<std::string>(msg[1]);
    auto method = broker::get<std::string>(msg[2]);
    auto args = broker::get<std::vector<broker::data>>(msg[3]);

    std::vector<broker::data> result_args;

    try {
        std::lock_guard<std::mutex> lock(rpc_handlers_mutex);
        auto it = rpc_handlers.find(method);
        if (it != rpc_handlers.end()) {
            auto result = it->second(std::move(args));
            result_args = {broker::data{request_id},
                         broker::data{result},
                         broker::data{std::string{}}};
        } else {
            result_args = {broker::data{request_id},
                         broker::data{broker::data{}},
                         broker::data{"method not found"}};
        }
    } catch (const std::exception& e) {
        result_args = {broker::data{request_id},
                     broker::data{broker::data{}},
                     broker::data{e.what()}};
    }

    // 发送响应
    broker::message resp{"zeek/rpc/response", std::move(result_args)};
    endpoint.publish("zeek/rpc/response", resp);
    }
```

---

## 5. 数据存储

### 5.1 数据存储架构

```
┌─────────────────────────────────────────────────────────────┐
│                    数据存储架构                               │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐       │
│  │   Master    │ ← │   Master    │ ← │   Master    │       │
│  │   Store     │   │   Store     │   │   Store     │       │
│  └──────┬──────┘   └──────┬──────┘   └──────┬──────┘       │
│         │                   │                   │              │
│         │  Master <────────│----------------───│              │
│         │                   │                   │              │
│         ↓                   ↓                   ↓              │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐       │
│  │   Worker    │   │   Worker    │   │   Worker    │       │
│  │   Store     │   │   Store     │   │   Store     │       │
│  │  (Clone)    │   │  (Clone)    │   │  (Clone)    │       │
│  └─────────────┘   └─────────────┘   └─────────────┘       │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 数据存储操作

```cpp
// zeek/broker/Store.h — 数据存储接口

namespace broker {

// 存储类型
enum class StoreType {
    MASTER,     // 主存储（可写）
    CLONE,     // 克隆存储（只读副本）
    UNSPECIFIED
};

// 存储操作结果
using store_result = variant<data, error, std::nullptr_t>;

// 存储接口
class Store {
public:
    virtual ~Store() = default;

    // 获取值
    virtual store_result Get(const std::string& key) = 0;

    // 设置值
    virtual store_result Put(const std::string& key,
                            const data& value,
                            std::chrono::milliseconds ttl = {}) = 0;

    // 删除值
    virtual store_result Erase(const std::string& key) = 0;

    // 原子递增
    virtual store_result Incr(const std::string& key,
                             int64_t delta = 1) = 0;

    // 批量操作
    virtual std::vector<std::pair<std::string, data>>
    Keys() = 0;

    virtual std::vector<std::pair<std::string, data>>
    All() = 0;
};

} // namespace broker
```

### 5.3 使用数据存储

```cpp
// zeek/broker/Store.cc — 数据存储操作

// 创建主存储
std::shared_ptr<broker::Store>
BrokerComm::CreateMasterStore(const std::string& name)
    {
    auto store = endpoint.make_master_store(name);
    master_stores[name] = store;
    return store;
    }

// 创建克隆存储（自动同步）
std::shared_ptr<broker::Store>
BrokerComm::CreateCloneStore(const std::string& name,
                            const std::string& master_peer)
    {
    auto store = endpoint.clone_store(name, master_peer);
    clone_stores[name] = store;
    return store;
    }

// 存储操作示例
void StoreExample()
    {
    auto store = endpoint.make_master_store("connection-table");

    // Put
    store->Put("192.168.1.100:80", broker::data{
        broker::record{
            {"state", broker::data{"ESTABLISHED"}},
            {"bytes", broker::data{12345}},
            {"last_seen", broker::data{std::chrono::steady_clock::now()}}
        }
    });

    // Get
    auto result = store->Get("192.168.1.100:80");
    if (auto* rec = std::get_if<broker::record>(&result)) {
        // 处理记录
    }

    // Incr
    store->Incr("192.168.1.100:80:bytes", 100);
    }
```

---

## 6. 消息序列化

### 6.1 Broker 数据类型

```cpp
// zeek/broker/Data.h — Broker 数据类型

namespace broker {

// 变体类型
using data = std::variant<
    std::nullptr_t,
    bool,
    int64_t,
    uint64_t,
    double,
    std::string,
    broker::address,
    broker::subnet,
    broker::port,
    broker::timestamp,
    broker::timespan,
    broker::enum_type,
    broker::set,
    broker::vector,
    broker::table,
    broker::record
>;

// Zeek 类型到 Broker 类型的映射
class DataConverter {
public:
    static broker::data FromZeekVal(const Val* val);
    static ValPtr ToZeekVal(const broker::data& data);

private:
    static ValPtr RecordToZeek(const broker::record& rec);
    static ValPtr VectorToZeek(const broker::vector& vec);
    static ValPtr TableToZeek(const broker::table& tbl);
};

} // namespace broker
```

### 6.2 Zeek 值序列化

```cpp
// zeek/broker/Data.cc — Zeek 值序列化

broker::data DataConverter::FromZeekVal(const Val* val)
    {
    switch (val->Type()->Tag()) {
    case TYPE_BOOL:
        return broker::data{val->AsBool()};

    case TYPE_INT:
        return broker::data{val->AsInt()};

    case TYPE_COUNT:
        return broker::data{val->AsCount()};

    case TYPE_DOUBLE:
        return broker::data{val->AsDouble()};

    case TYPE_STRING:
        return broker::data{val->AsString()->ToStdString()};

    case TYPE_ADDR:
        return broker::data{broker::address{val->AsAddr()}};

    case TYPE_SUBNET:
        return broker::data{broker::subnet{val->AsSubNet()}};

    case TYPE_PORT:
        return broker::data{broker::port{val->AsPort()}};

    case TYPE_ENUM:
        return broker::data{broker::enum_type{
            val->GetType()->Name(),
            val->AsEnum()
        }};

    case TYPE_RECORD: {
        broker::record rec;
        auto rval = val->AsRecord();
        for (auto i = 0; i < rval->NumFields(); ++i) {
            if (auto field_val = rval->GetField(i))
                rec.fields.push_back(FromZeekVal(field_val.get()));
            else
                rec.fields.push_back(broker::data{});
        }
        return broker::data{rec};
    }

    case TYPE_VECTOR: {
        broker::vector vec;
        auto vval = val->AsVector();
        for (auto& elem : *vval)
            vec.push_back(FromZeekVal(elem.get()));
        return broker::data{vec};
    }

    case TYPE_TABLE: {
        broker::table tbl;
        auto tval = val->AsTable();
        for (auto& [key, value] : *tval) {
            tbl.keys.push_back(FromZeekVal(key.get()));
            tbl.values.push_back(FromZeekVal(value.get()));
        }
        return broker::data{tbl};
    }

    default:
        return broker::data{};
    }
    }
```

---

## 7. 节点发现与连接

### 7.1 节点发现机制

```cpp
// zeek/broker/Peer.h/.cc — 节点发现

namespace broker {

// 节点端点信息
struct EndpointInfo {
    std::string id;             // 节点 ID
    network::address addr;      // 地址
    uint16_t port;              // 端口
    std::string type;           // 节点类型
    std::map<std::string, std::string> meta;  // 元数据
};

// Peer 状态
enum class PeerStatus {
    CONNECTING,
    CONNECTED,
    DISCONNECTED,
    FAILED
};

} // namespace broker

// Peer 管理
class PeerManager {
public:
    // 添加静态 Peer
    void AddPeer(const broker::EndpointInfo& info);

    // 移除 Peer
    void RemovePeer(const std::string& id);

    // 获取所有 Peer
    std::vector<broker::EndpointInfo> GetAllPeers();

    // Peer 状态变更回调
    std::function<void(const broker::EndpointInfo&, PeerStatus)>
        on_status_change;

private:
    std::map<std::string, broker::EndpointInfo> peers;
    std::map<std::string, PeerStatus> peer_status;
    std::mutex mutex;
};
```

### 7.2 节点连接流程

```cpp
// zeek/broker/Peer.cc — 节点连接

// 连接到 Peer
void BrokerComm::ConnectToPeer(const std::string& host,
                               uint16_t port,
                               std::chrono::milliseconds timeout)
    {
    // 1. 解析地址
    auto addr = broker::network_address{host, port};

    // 2. 发起连接
    auto fut = endpoint.peers().add(addr);

    // 3. 等待连接完成
    auto res = fut.get(timeout);

    if (res) {
        // 连接成功
        ++stats.successful_connections;
        NotifyPeerConnected(host, port);
    } else {
        // 连接失败
        ++stats.failed_connections;
        NotifyPeerFailed(host, port, res.error());
    }
    }

// 处理对端状态变更
void BrokerComm::HandlePeerStatus(const broker::status& s)
    {
    if (auto* ps = std::get_if<peer_added>(&s)) {
        // 新对端加入
        std::lock_guard<std::mutex> lock(peers_mutex);
        peers[ps->endpoint.id] = *ps;
        OnPeerConnected(ps->endpoint);

    } else if (auto* ps = std::get_if<peer_lost>(&s)) {
        // 对端丢失
        std::lock_guard<std::mutex> lock(peers_mutex);
        peers.erase(ps->endpoint.id);
        OnPeerDisconnected(ps->endpoint);
    }
    }
```

---

## 8. ZeekControl 协议

### 8.1 ZeekControl 消息类型

```cpp
// zeek/control/Control.h — ZeekControl 消息

namespace zeek::control {

// 控制消息类型
enum class MessageType : uint8_t {
    // 节点管理
    NODE_STATUS_QUERY,        // 查询节点状态
    NODE_STATUS_RESPONSE,     // 节点状态响应
    NODE_START,               // 启动节点
    NODE_STOP,                // 停止节点
    NODE_RESTART,             // 重启节点

    // 配置管理
    CONFIG_GET,               // 获取配置
    CONFIG_SET,               // 设置配置
    CONFIG_SYNC,              // 同步配置

    // 日志管理
    LOG_LEVEL_SET,            // 设置日志级别
    LOG_ROTATE,               // 轮转日志

    // 脚本控制
    SCRIPT_LOAD,              // 加载脚本
    SCRIPT_UNLOAD,             // 卸载脚本
    SCRIPT_RELOAD,             // 重载脚本
};

// 节点状态
struct NodeStatus {
    std::string node_id;
    NodeType type;
    ProcessState state;       // RUNNING, STOPPED, FAILED
    uint64_t uptime;           // 运行时间（秒）
    double cpu_usage;          // CPU 使用率
    uint64_t memory_usage;     // 内存使用（字节）
    uint64_t events_processed; // 处理的事件数
};

// 控制消息
struct ControlMessage {
    MessageType type;
    std::string sender_id;
    std::string target_id;     // 目标节点（空表示广播）
    uint64_t sequence;          // 序列号
    std::vector<uint8_t> payload;
};

} // namespace zeek::control
```

### 8.2 节点状态查询

```zeek
# ZeekScript 中的节点状态查询
event Cluster::node_status_query(node_id: string)
    {
    # 获取本地节点信息
    local status: Control::NodeStatus = [
        $node_id = node_id,
        $type = Cluster::node_type,
        $state = Cluster::node_state,
        $uptime = current_time() - Cluster::start_time,
        $cpu_usage = get_cpu_usage(),
        $memory_usage = get_memory_usage(),
        $events_processed = stats$events_processed
    ];

    # 发送响应
    Broker::publish(Cluster::manager_topic,
                   Cluster::node_status_response,
                   status);
    }
```

---

## 9. 日志传输

### 9.1 日志批量传输

```cpp
// zeek/broker/LogTransfer.h — 日志传输

// 日志批量
struct LogBatch {
    std::string logger_id;           // Logger ID
    std::string stream;              // 日志流名称
    uint64_t first_ts;               // 首个日志时间戳
    uint64_t last_ts;                // 最后日志时间戳
    uint32_t count;                  // 日志条数
    std::vector<std::string> lines;  // 日志内容
};

// 日志写入请求
struct LogWriteRequest {
    std::string path;                // 输出路径
    bool append;                     // 是否追加
    std::vector<std::string> lines;  // 日志行
};
```

### 9.2 日志聚合流程

```cpp
// zeek/cluster/LogAggregator.cc — 日志聚合

void LogAggregator::Aggregate(const LogBatch& batch)
    {
    std::lock_guard<std::mutex> lock(mutex);

    // 1. 按流分组
    auto stream_id = MakeStreamID(batch.logger_id, batch.stream);

    // 2. 检查是否需要创建 Writer
    if (! HasWriter(stream_id)) {
        CreateWriter(stream_id, batch.stream);
    }

    // 3. 批量写入
    auto& writer = GetWriter(stream_id);
    for (const auto& line : batch.lines) {
        writer->Write(line);
    }

    // 4. 更新统计
    stats[stream_id].batches_received++;
    stats[stream_id].lines_received += batch.count;
    }

// 创建日志写入器
void LogAggregator::CreateWriter(const std::string& stream_id,
                                 const std::string& stream_name)
    {
    auto writer = log_manager->CreateWriter(
        fmt("%s/%s.log", output_dir, stream_name));

    writers[stream_id] = std::move(writer);

    // 检查是否需要轮转
    if (ShouldRotate(writer.get())) {
        writer->Rotate();
    }
    }
```

---

## 10. 安全通信

### 10.1 SSL/TLS 配置

```cpp
// zeek/broker/SSL.h/.cc — SSL 配置

namespace broker {

// SSL 配置
struct SSLConfig {
    bool enable;              // 是否启用
    std::string ca_file;      // CA 证书
    std::string cert_file;   // 节点证书
    std::string key_file;     // 私钥
    bool verify_peers;        // 验证对端证书
    std::string ciphers;      // 密码套件
};

// 创建 SSL 上下文
class SSLContext {
public:
    static std::unique_ptr<SSLContext> Create(const SSLConfig& config);

    // 获取 SSL 上下文
    SSL_CTX* GetContext() { return ctx_; }

private:
    SSL_CTX* ctx_;
};

} // namespace broker
```

### 10.2 启用 TLS

```cpp
// zeek/broker/SSL.cc — TLS 配置

void BrokerComm::EnableTLS(const SSLConfig& config)
    {
    // 1. 创建 SSL 上下文
    ssl_ctx = SSLContext::Create(config);

    // 2. 配置 Endpoint
    endpoint.enable_tls(ssl_ctx->GetContext());

    // 3. 设置验证回调
    if (config.verify_peers) {
        endpoint.set_verify_callback(
            [](broker::network::address addr,
               broker::certificate::pointer cert) -> bool {
                // 验证对端证书
                return VerifyCertificate(cert);
            });
    }

    stats.tls_enabled = true;
    }
```

---

## 11. 总结

本章介绍了 Zeek 集群通信的核心内容：

| 组件                | 功能           | 关键源码                  |
| :------------------ | :------------- | :------------------------ |
| **Broker Endpoint** | 通信端点管理   | `zeek/broker/Manager.cc`  |
| **Pub/Sub**         | 发布订阅消息   | `zeek/broker/Comm.cc`     |
| **RPC**             | 远程过程调用   | `zeek/broker/RPC.cc`      |
| **Data Store**      | 分布式键值存储 | `zeek/broker/Store.cc`    |
| **Peer Manager**    | 节点发现与连接 | `zeek/broker/Peer.cc`     |
| **ZeekControl**     | 控制协议       | `zeek/control/Control.cc` |

下一章我们将讨论**负载均衡**，包括 PF_RING、AF_PACKET 负载均衡的实现以及 Flow 哈希算法。

---

> [!previous] 上一章：[[2026-04-15-zeek-deep-dive-ch26-cluster-config|第二十六章：集群配置]]
> [!next] 下一章：[[2026-04-15-zeek-deep-dive-ch28-load-balancing|第二十八章：负载均衡]]
