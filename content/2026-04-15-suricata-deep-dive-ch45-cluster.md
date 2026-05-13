---
title: "Suricata 深度探索 (四十五)：集群模式"
date: 2026-04-15
tags:
  - suricata
  - series
  - cluster
  - unix-socket
  - cluster-mode
  - distributed
  - high-availability
description: "深入解析 Suricata 集群模式：unix-cluster 配置、CS 缓冲区、Cluster Node 架构、分布式 Flow 负载均衡、EVE 聚合输出、以及集群管理"
---

> [!info] Suricata 2026 深度探索系列 0. [[2026-04-15-suricata-deep-dive-series-index|全栈学习路径总览]]
> ... 43. [[2026-04-15-suricata-deep-dive-ch43-app-layer-register|第四十三章：自定义协议 Parser]] 44. [[2026-04-15-suricata-deep-dive-ch44-rust|第四十四章：Rust 扩展]] 45. **第四十五章：集群模式**

---

## 1. 集群模式概述

Suricata 的 **集群模式（Cluster Mode）** 提供**分布式多节点部署**能力，通过 Unix Domain Socket 或 TCP 进行节点间通信，实现：

- **横向扩展**：增加节点提升检测吞吐量
- **高可用**：单节点故障不影响整体检测
- **统一管理**：单一配置/规则同步
- **流量分担**：Flow 级别负载均衡

```
graph TD
    subgraph "Suricata 集群"
        subgraph "Node 1"
            N1W[\"Worker#1\"]
            N1W2[\"Worker#2\"]
            N1M[\"Management\"]
        end
        subgraph "Node 2"
            N2W[\"Worker#1\"]
            N2W2[\"Worker#2\"]
            N2M[\"Management\"]
        end
        subgraph "Node 3"
            N3W[\"Worker#1\"]
            N3W2[\"Worker#2\"]
            N3M[\"Management\"]
        end
    end

    subgraph "负载均衡器"
        LB[\"L4 LB<br/>(IP Hash)\"]
    end

    subgraph "统一输出"
        EVE[\"EVE Aggregator\"]
        FILE[\"File Store\"]
    end

    LB --> N1W
    LB --> N2W
    LB --> N3W

    N1W <--> CS[\"Unix Socket<br/>Cluster Bus\"]
    N2W <--> CS
    N3W <--> CS

    N1W --> EVE
    N2W --> EVE
    N3W --> EVE

    N1W --> FILE
    N2W --> FILE
    N3W --> FILE
```

### 1.1 集群模式 vs 单机模式

| 特性          | 单机模式         | 集群模式          |
| :------------ | :--------------- | :---------------- |
| **部署规模**  | 单节点           | 多节点            |
| **负载均衡**  | 线程级（AutoFP） | 节点级（CS + LB） |
| **Flow 共享** | 本地哈希表       | Unix Socket 总线  |
| **EVE 输出**  | 本地文件         | 聚合到中心节点    |
| **规则同步**  | 手动分发         | 共享配置          |
| **故障恢复**  | 无               | 节点故障隔离      |

### 1.2 集群架构

```
graph LR
    subgraph "Cluster Node"
        subgraph "Worker"
            RX[\"Receive (Rx)\"]
            DEC[\"Decode\"]
            DET[\"Detect\"]
            TX[\"Transmit (Tx)\"]
        end
        CS[\"CSocket<br/>Cluster Socket\"]
    end

    RX --> DEC
    DEC --> DET
    DET --> TX

    RX <--> CS
    DEC <--> CS
    DET <--> CS
    TX <--> CS
```

---

## 2. unix-cluster 配置详解

### 2.1 基础配置

```yaml
# suricata.yaml — 集群模式配置
cluster:
  # 集群类型
  type: unixSocket # unixSocket | tcp

  # Unix Socket 路径
  unix-socket:
    # Socket 文件路径
    filename: /var/run/suricata/cluster.sock

    # 缓冲区大小
    buffer-size: 16384

    # 超时设置
    read-timeout: 100 # ms
    write-timeout: 100 # ms

  # 集群 ID
  cluster-id: 1 # 1-255，每个节点唯一

  # 节点间通信
  inter:
    # 心跳间隔
    heartbeat: 1000 # ms

    # 节点超时
    node-timeout: 5000 # ms

  # 负载均衡策略
  load-balance:
    # Hash 方式
    mode: flow # flow | round-robin | static
    # hash 元数据
    hash: [src, dst, sp, dp] # 5-tuple hash
```

### 2.2 TCP 集群配置

```yaml
# suricata.yaml — TCP 集群模式
cluster:
  type: tcp

  # TCP 配置
  tcp:
    # 监听地址
    bind-address: 0.0.0.0
    port: 5555

    # 节点发现
    discovery:
      enabled: yes
      multicast-group: 239.0.0.1
      multicast-port: 5556

    # 心跳
    heartbeat:
      enabled: yes
      interval: 1000 # ms

  # 集群 ID（每个节点唯一）
  cluster-id: 1

  # 负载均衡
  load-balance:
    mode: flow # flow | round-robin
    hash: [src, dst, sp, dp]
```

### 2.3 Worker 集群配置

```yaml
# suricata.yaml — Worker 节点配置
cluster:
  type: worker # worker | management

  # 上级管理节点
  management:
    address: 10.0.0.1
    port: 5555

  # 本地 Worker 配置
  worker:
    # CPU 亲和
    cpu-affinity: [4, 5, 6, 7]

    # 每个 CPU 的 Worker 数
    threads-per-cpu: 1

# runmode 必须是 cluster 模式
runmode: cluster
```

### 2.4 Management 节点配置

```yaml
# suricata.yaml — Management 节点配置
cluster:
  type: management # management | worker

  # 管理服务端口
  management:
    address: 0.0.0.0
    port: 5555

  # 配置分发
  config-sync:
    enabled: yes
    path: /etc/suricata/ # 共享配置路径
    interval: 30 # 同步间隔（秒）

  # 规则同步
  rule-sync:
    enabled: yes
    path: /var/lib/suricata/rules/
    url: "file:///etc/suricata/rules/"

  # EVE 聚合
  eve-aggregation:
    enabled: yes
    output: /var/log/suricata/eve.json
    flush-interval: 100 # ms
```

---

## 3. Cluster Socket 核心

### 3.1 CSocket 数据结构

```c
// src/util-csocket.h — Cluster Socket
typedef struct CSocket_ {
    /* Socket 类型 */
    CSocketType type;
#define CSOCKET_TYPE_UNIX  0
#define CSOCKET_TYPE_TCP   1

    /* Socket FD */
    int fd;

    /* 读写缓冲区 */
    uint8_t *read_buffer;
    uint32_t read_buffer_size;
    uint8_t *write_buffer;
    uint32_t write_buffer_size;

    /* 发送队列 */
    TAILQ_HEAD(, CSMessage_) send_queue;
    uint32_t send_queue_len;

    /* 统计 */
    uint64_t bytes_sent;
    uint64_t bytes_recv;
    uint64_t messages_sent;
    uint64_t messages_recv;
} CSocket;
```

### 3.2 Cluster Message

```c
// src/util-csocket.h — 集群消息
typedef struct CSMessage_ {
    /* 消息类型 */
    uint8_t type;
#define CS_MSG_TYPE_PACKET      0x01  // 数据包
#define CS_MSG_TYPE_FLOW        0x02  // Flow 同步
#define CS_MSG_TYPE_ALERT       0x03  // 告警
#define CS_MSG_TYPE_STATS       0x04  // 统计
#define CS_MSG_TYPE_HEARTBEAT   0x05  // 心跳
#define CS_MSG_TYPE_CONFIG      0x06  // 配置同步
#define CS_MSG_TYPE_SHUTDOWN    0x07  // 关闭通知

    /* 源节点 ID */
    uint8_t src_node_id;

    /* 目标节点 ID（广播为 0xFF）*/
    uint8_t dst_node_id;

    /* 消息长度 */
    uint32_t len;

    /* 消息数据 */
    uint8_t data[];

    TAILQ_ENTRY(CSMessage_) next;
} CSMessage;

// 数据包消息
typedef struct CSPacketMsg_ {
    uint32_t pkthdr_len;         // Packet 头部长度
    uint32_t pktdata_len;        // Packet 数据长度
    struct timespec ts;          // 时间戳
    uint32_t hash;               // Flow hash
    /* 后面跟着 Packet 数据 */
} CSPacketMsg;
```

### 3.3 CSocket 读写

```c
// src/util-csocket.c — 发送数据包
int CSocketSendPacket(CSocket *cs, const Packet *p)
{
    /* 构造消息 */
    CSPacketMsg msg;
    msg.pkthdr_len = sizeof(CSPacketMsg);
    msg.pktdata_len = p->pktlen;
    msg.ts = p->ts;
    msg.hash = p->flow_hash;

    /* 分配发送缓冲 */
    uint32_t total_len = sizeof(CSPacketMsg) + p->pktlen;
    uint8_t *buf = SCCalloc(1, total_len);
    memcpy(buf, &msg, sizeof(CSPacketMsg));
    memcpy(buf + sizeof(CSPacketMsg), p->pkt, p->pktlen);

    /* 发送到 Unix Socket */
    int ret = CSocketWrite(cs, buf, total_len);
    SCFree(buf);

    if (ret > 0) {
        cs->bytes_sent += ret;
        cs->messages_sent++;
    }

    return ret;
}

// Unix Socket 写
static int CSocketWrite(CSocket *cs, const uint8_t *data, uint32_t len)
{
    if (cs->type == CSOCKET_TYPE_UNIX) {
        return write(cs->fd, data, len);
    } else {
        /* TCP 封装：先写长度头 */
        uint32_t net_len = htonl(len);
        write(cs->fd, &net_len, 4);
        return write(cs->fd, data, len);
    }
}
```

---

## 4. 节点发现与心跳

### 4.1 节点注册

```c
// src/util-cluster.c — 节点管理
typedef struct ClusterNode_ {
    uint8_t node_id;             // 节点 ID
    char *name;                  // 节点名称
    CSocket *socket;             // 连接 socket

    /* 节点状态 */
    uint8_t state;
#define NODE_STATE_INIT      0
#define NODE_STATE_CONNECTED 1
#define NODE_STATE_ACTIVE    2
#define NODE_STATE_DEAD       3

    /* 心跳 */
    uint64_t last_heartbeat;
    uint32_t missed_heartbeats;

    /* 统计 */
    uint64_t pkts_received;
    uint64_t pkts_sent;

    TAILQ_ENTRY(ClusterNode_) next;
} ClusterNode;

static TAILQ_HEAD(, ClusterNode_) g_cluster_nodes;
static SCMutex g_cluster_lock;
```

### 4.2 心跳机制

```c
// src/util-cluster.c — 心跳
static void *ClusterHeartbeatThread(void *arg)
{
    ThreadVars *tv = (ThreadVars *)arg;

    while (!tv->quit) {
        sleep(1);

        ClusterNode *node;
        TAILQ_FOREACH(node, &g_cluster_nodes, next) {
            /* 发送心跳 */
            CSMessage hb;
            hb.type = CS_MSG_TYPE_HEARTBEAT;
            hb.src_node_id = g_local_node_id;
            hb.dst_node_id = node->node_id;
            hb.len = 0;

            CSocketSend(node->socket, (uint8_t *)&hb, sizeof(hb));

            /* 检查超时 */
            uint64_t now = TimeGet();
            if (now - node->last_heartbeat > NODE_TIMEOUT) {
                node->missed_heartbeats++;
                if (node->missed_heartbeats > 3) {
                    SCLogWarning("Cluster node %d is dead",
                                 node->node_id);
                    node->state = NODE_STATE_DEAD;
                }
            }
        }
    }

    return NULL;
}
```

---

## 5. Flow 负载均衡

### 5.1 Flow 分配算法

```c
// src/util-cluster.c — Flow 分配
typedef struct ClusterFlowLB_ {
    /* 节点列表 */
    ClusterNode **nodes;
    uint32_t node_count;

    /* Hash 函数 */
    ClusterHashFunc hash_func;

    /* 一致性哈希 */
    CHashRing *ring;
} ClusterFlowLB;

uint8_t ClusterSelectNode(ClusterFlowLB *lb, const Packet *p)
{
    /* 计算 Flow hash */
    FlowKey key;
    memset(&key, 0, sizeof(key));
    key.src_ip = p->src_addr;
    key.dst_ip = p->dst_addr;
    key.sp = p->sp;
    key.dp = p->dp;
    key.proto = p->proto;

    uint32_t flow_hash = lb->hash_func(&key, sizeof(key));

    /* 一致性 Hash 查找 */
    return CHashRingLookup(lb->ring, flow_hash);
}

// 默认 hash 函数
static uint32_t ClusterHashFlow(const void *data, size_t len)
{
    const FlowKey *key = (const FlowKey *)data;
    uint32_t hash = key->src_ip ^ (key->dst_ip << 1);
    hash ^= key->sp ^ (key->dp << 1);
    hash ^= key->proto;
    return hash;
}
```

### 5.2 Flow 跨节点同步

```c
// src/util-cluster.c — Flow 同步消息
typedef struct CSFlowMsg_ {
    uint32_t hash;               // Flow hash
    uint8_t state;               // Flow 状态
    uint64_t created;            // 创建时间
    uint64_t last_update;        // 最后更新时间
    /* Flow 数据 */
    FlowDataBlock block;
} CSFlowMsg;

// Flow 状态同步
void ClusterSyncFlow(Flow *f, ClusterNode *target)
{
    /* 构造 Flow 同步消息 */
    CSFlowMsg msg;
    msg.hash = FlowHash(f);
    msg.state = f->flow_state;
    msg.created = f->created;
    msg.last_update = f->last_update;

    /* 复制 Flow 数据 */
    FlowSerialize(f, &msg.block);

    /* 发送到目标节点 */
    CSMessage cs_msg;
    cs_msg.type = CS_MSG_TYPE_FLOW;
    cs_msg.src_node_id = g_local_node_id;
    cs_msg.dst_node_id = target->node_id;
    cs_msg.len = sizeof(CSFlowMsg);
    memcpy(cs_msg.data, &msg, sizeof(CSFlowMsg));

    CSocketSend(target->socket, (uint8_t *)&cs_msg, sizeof(cs_msg));
}
```

---

## 6. 告警聚合与 EVE

### 6.1 分布式告警去重

```c
// src/output-ClusterAlert.c — 告警聚合
typedef struct ClusterAlertAgg_ {
    /* 去重表：GID/SID/源IP → 首次时间 */
    GHashTable *dedup_table;

    /* 聚合窗口 */
    struct timeval window_start;
    uint32_t window_ms;
} ClusterAlertAgg;

static uint64_t AlertDedupKey(int32_t gid, int32_t sid,
                               uint32_t src_ip)
{
    /* 构造去重 key */
    return ((uint64_t)gid << 48) |
           ((uint64_t)sid << 32) |
           ((uint64_t)src_ip);
}

static int ClusterAlertCheckDuplicate(ClusterAlertAgg *agg,
                                       const Packet *p,
                                       const Signature *s)
{
    uint64_t key = AlertDedupKey(s->gid, s->id, p->src_addr);

    /* 检查去重表 */
    uint64_t *first_seen = g_hash_table_lookup(agg->dedup_table, key);
    uint64_t now = TimeGetMS();

    if (first_seen == NULL) {
        /* 首次告警 */
        g_hash_table_insert(agg->dedup_table, key, now);
        return 1;
    }

    /* 窗口内去重 */
    if (now - *first_seen < agg->window_ms) {
        return 0;  // 重复
    }

    /* 更新首次时间 */
    *first_seen = now;
    return 1;
}
```

### 6.2 EVE 聚合输出

```yaml
# suricata.yaml — Management 节点 EVE 配置
outputs:
  - eve-log:
      enabled: yes
      filename: eve-cluster.json

      # 聚合来自 Worker 节点的日志
      cluster:
        enabled: yes
        input: /var/run/suricata/cluster.sock

      # 类型过滤
      types:
        - alert
        - anomaly
        - dns
        - http
        - tls
```

### 6.3 EVE JSON 聚合格式

```json
{
  "timestamp": "2026-04-15T10:30:00.000000+0000",
  "event_type": "alert",
  "cluster": {
    "node_id": 2,
    "node_name": "worker-node-02"
  },
  "src_ip": "192.168.1.100",
  "dest_ip": "10.0.0.1",
  "alert": {
    "signature_id": 1000001,
    "signature": "ET MALWARE",
    "category": "A Network Trojan was detected"
  }
}
```

---

## 7. 集群部署示例

### 7.1 部署拓扑

```
┌─────────────────────────────────────────────────────────┐
│                    管理网络 (10.0.10.0/24)                │
│                                                          │
│  ┌─────────────┐   ┌─────────────┐   ┌─────────────┐    │
│  │  Mgmt Node  │   │  Worker #1  │   │  Worker #2  │    │
│  │  (控管面)   │◄─►│  (检测节点)  │◄─►│  (检测节点)  │    │
│  │  eth0: .1   │   │  eth0: .2   │   │  eth0: .3   │    │
│  └─────────────┘   └─────────────┘   └─────────────┘    │
└─────────────────────────────────────────────────────────┘
                         ▲
                         │
┌─────────────────────────────────────────────────────────┐
│                    业务网络 (监控口)                      │
│                                                          │
│   ┌───────────┐    ┌───────────┐    ┌───────────┐      │
│   │  Switch   │───►│  Worker#1 │───►│  Worker#2 │      │
│   │  (SPAN)   │    │   eth1    │    │   eth1    │      │
│   └───────────┘    └───────────┘    └───────────┘      │
└─────────────────────────────────────────────────────────┘
```

### 7.2 Management 节点配置

```yaml
# suricata-mgmt.yaml — Management 节点
%YAML 1.1
---
# 接口
vars:
  address-groups:
    HOME_NET: "[10.0.0.0/8,192.168.0.0/16]"

# 集群配置
cluster:
  type: management
  management:
    address: 0.0.0.0
    port: 5555

  # 配置同步
  config-sync:
    enabled: yes
    path: /etc/suricata/
    interval: 60

  # 规则同步
  rule-sync:
    enabled: yes
    url: "http://10.0.10.1:8888/rules/"

# 输出
outputs:
  - eve-log:
      enabled: yes
      filename: /var/log/suricata/eve.json
      types:
        - alert
        - anomaly
        - dns
        - http
        - tls
        - files

# runmode
runmode: cluster
```

### 7.3 Worker 节点配置

```yaml
# suricata-worker.yaml — Worker 节点
%YAML 1.1
---
# 上级管理节点
cluster:
  type: worker
  management:
    address: 10.0.10.1
    port: 5555
  cluster-id: 2

# 捕获配置（AF-PACKET）
af-packet:
  - interface: eth1
    threads: 16
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    ring-size: 4096

# runmode
runmode: cluster_worker

# threading
threading:
  cpu-affinity:
    - cpu: [0-3]
      mode: "exclusive"
      threads: 1
    - cpu: [4-19]
      mode: "exclusive"
      threads: 16
```

### 7.4 启动脚本

```bash
#!/bin/bash
# start-cluster.sh

# 启动 Management 节点
suricata -c /etc/suricata/suricata-mgmt.yaml \
    --set cluster.type=management \
    -D --pidfile /var/run/suricata/mgmt.pid

sleep 2

# 启动 Worker 节点
for i in 1 2; do
    CLUSTER_ID=$((i + 1))
    SSH worker-${i} "suricata -c /etc/suricata/suricata-worker.yaml \
        --set cluster.cluster-id=${CLUSTER_ID} \
        -D --pidfile /var/run/suricata/worker-${i}.pid"
done

echo "Cluster started"
```

---

## 8. 高可用与故障恢复

### 8.1 故障检测

```c
// src/util-cluster.c — 节点故障处理
static void ClusterHandleNodeFailure(ClusterNode *node)
{
    SCLogWarning("Cluster node %d (%s) failed", node->node_id, node->name);

    /* 标记该节点上的 Flow 为待重分配 */
    FlowMarkForRedistribute(node->node_id);

    /* 从节点列表移除 */
    SCMutexLock(&g_cluster_lock);
    TAILQ_REMOVE(&g_cluster_nodes, node, next);
    SCMutexUnlock(&g_cluster_lock);

    /* 关闭连接 */
    CSocketClose(node->socket);

    /* 释放资源 */
    ClusterNodeFree(node);
}
```

### 8.2 Flow 重新分配

```c
// src/util-cluster.c — Flow 重新分配
void FlowRedistributeToNode(uint32_t flow_hash, uint8_t failed_node_id)
{
    /* 从一致性 Hash 环移除故障节点 */
    CHashRingRemove(g_lb.ring, failed_node_id);

    /* 查找新节点 */
    ClusterNode *new_node = CHashRingLookup(g_lb.ring, flow_hash);
    if (new_node == NULL) {
        /* 无可用节点，放置本地 */
        new_node = ClusterNodeSelf();
    }

    /* 发送 Flow 到新节点 */
    Flow *f = FlowGetByHash(flow_hash);
    if (f != NULL) {
        ClusterSyncFlow(f, new_node);
        FlowUnlock(f);
    }
}
```

---

## 9. 性能调优

### 9.1 Socket 缓冲区调优

```yaml
# suricata.yaml
cluster:
  unix-socket:
    # 增大缓冲区提升吞吐
    buffer-size: 65536 # 64KB

  # 批量发送
  batch:
    size: 64 # 每批消息数
    timeout: 10 # ms

  # 多队列
  mq:
    send-queues: 4 # 发送队列数
    recv-queues: 4 # 接收队列数
```

### 9.2 内核参数调优

```bash
# /etc/sysctl.conf — 内核调优
# Unix Socket 缓冲区
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 65536
net.core.wmem_default = 65536

# Socket 连接队列
net.core.somaxconn = 1024
net.core.netdev_max_backlog = 50000
```

---

## 10. 小结

本章解析了 Suricata 集群模式：

1. **集群架构**：Management + Worker 节点，Unix Socket / TCP 通信
2. **unix-cluster 配置**：socket 路径、buffer-size、heartbeat
3. **CSocket**：消息类型（Packet/Flow/Alert/Stats）、读写协议
4. **节点发现**：心跳机制、节点状态机（INIT → CONNECTED → ACTIVE → DEAD）
5. **Flow 负载均衡**：一致性 Hash（CHashRing）、Flow 跨节点同步
6. **EVE 聚合**：告警去重、窗口聚合、JSON 合并
7. **部署拓扑**：Management 控制面、Worker 检测面分离
8. **高可用**：故障检测、Flow 重新分配、一致性 Hash 环更新
9. **性能调优**：Socket buffer 批量发送、多队列优化
