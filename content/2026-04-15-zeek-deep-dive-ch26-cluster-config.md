---
title: "Zeek 深度探索 (二十六)：集群配置"
date: 2026-04-15
tags:
  - zeek
  - series
  - cluster
  - zeekctl
  - node.cfg
  - cluster-layout
  - configuration
description: "深入解析 Zeek 集群配置——node.cfg、cluster-layout.zeek、流量分发配置、ZeekControl 配置项详解"
---

> [!info] Zeek 2026 深度探索系列
> 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ...
> 25. [[2026-04-15-zeek-deep-dive-ch25-cluster-arch|第二十五章：集群架构]]
> 26. **第二十六章：集群配置**
> 27. [[2026-04-15-zeek-deep-dive-ch27-communication|第二十七章：通信]]
> 28. [[2026-04-15-zeek-deep-dive-ch28-load-balancing|第二十八章：负载均衡]]
> 29. [[2026-04-15-zeek-deep-dive-ch29-packet-loss|第二十九章：丢包处理]]

---

## 1. ZeekControl 配置概述

ZeekControl 是 Zeek 集群的管理平面，通过 `zeekctl` 命令行工具管理集群。

### 1.1 配置文件结构

```
$ZEEK_HOME/etc/
├── zeekctl.cfg              # ZeekControl 主配置
├── node.cfg                 # 节点配置（每节点一行）
├── cluster-layout.zeek      # 集群拓扑脚本
├── networks.cfg             # 网络定义
└── scripts/                 # ZeekScript 脚本目录
    ├── site/                # 本地站点脚本
    └── cluster/             # 集群相关脚本
```

### 1.2 zeekctl.cfg 主配置

```ini
# zeekctl.cfg — ZeekControl 主配置

[zeek]
# Zeek 二进制路径
zeek_binary = /usr/local/zeek/bin/zeek

# Zeek 选项
zeek_options = -U site

# 日志目录
log_dir = /var/log/zeek

# 运行目录
spool_dir = /var/spool/zeek

# 临时目录
tmp_dir = /tmp

[agent]
# Agent 配置（用于远程节点）
agent_binary = /usr/local/zeek/bin/zeek-agent
agent_port = 4777

[logger]
# Logger 配置
logger_binary = /usr/local/zeek/bin/zeek
default_log = ascii

# 日志轮转
log_rotation_interval = 3600    # 秒
log_rotation_size = 1073741824   # 1GB

[manager]
# Manager 配置
manager_binary = /usr/local/zeek/bin/zeek

# 崩溃转储
crash_dump_dir = /var/spool/zeek/crash-dumps

[proxy]
# Proxy 配置
proxy_binary = /usr/local/zeek/bin/zeek
num_proxies = 1

[worker]
# Worker 默认配置
worker_binary = /usr/local/zeek/bin/zeek

# 默认接口
interface = eth0

# CPU 亲和（逗号分隔）
cpu_affinity =

# Pin to core（实验性）
pin_cpus = false

# 每个接口的 Worker 数
num_workers = 1

# 数据包过滤器
pcapsize = 65535
snaplen = 65535

# 流量过滤
bpf_filter =

[broker]
# Broker 通信配置
broker_port = 47761/tcp
broker_host = 0.0.0.0

# Broker 网络配置
bind_address = 0.0.0.0
advertised_address =

# SSL/TLS
enable_ssl = false
ssl_cafile =
ssl_keyfile =
ssl_certfile =

# 序列化
serialization = broker

[mail]
# 邮件通知
sendmail = /usr/sbin/sendmail
mailto = security@example.com
mail_subject_prefix = [Zeek]

[logging]
# 日志级别
zeek_loglevel = INFO

# 是否启用实时日志
enable_remote_logging = true
```

---

## 2. node.cfg 节点配置

`node.cfg` 定义集群中每个节点的配置，每行一个节点。

### 2.1 node.cfg 格式

```ini
# node.cfg — 节点配置
# 格式: [nodename]
# type = manager|proxy|worker|logger
# host = hostname|IP
# ...

# ============ Manager ============
[manager]
type = manager
host = zeek-manager.example.com

# ============ Proxies ============
[proxy-1]
type = proxy
host = zeek-proxy-1.example.com

[proxy-2]
type = proxy
host = zeek-proxy-2.example.com

# ============ Loggers ============
[logger-1]
type = logger
host = zeek-logger-1.example.com

# ============ Workers ============
[worker-1]
type = worker
host = zeek-worker-1.example.com
interface = eth0
lb_method = pf_ring
lb_procs = 4

[worker-2]
type = worker
host = zeek-worker-2.example.com
interface = eth1
lb_method = pf_ring
lb_procs = 4

[worker-3]
type = worker
host = zeek-worker-3.example.com
interface = eth2
lb_method = af_packet
lb_procs = 2
```

### 2.2 节点类型配置

#### Manager 节点

```ini
[manager]
type = manager
host = manager.example.com

# Manager 特定选项
manager_port = 47762/tcp      # Manager 监听端口
proxy_port = 47761/tcp        # Proxy 监听端口
```

#### Proxy 节点

```ini
[proxy-1]
type = proxy
host = proxy1.example.com

# Proxy 特定选项
proxy_port = 47761/tcp
num_workers = 2              # 为这个 proxy 启动的 worker 数
```

#### Worker 节点

```ini
[worker-1]
type = worker
host = worker1.example.com

# 捕获配置
interface = eth0             # 监听接口
lb_method = pf_ring           # 负载均衡方法
lb_procs = 4                  # 进程数

# 高级选项
real_time_hardware = false    # 实时硬件时间戳
real_time_mode = false        # 实时模式
```

#### Logger 节点

```ini
[logger-1]
type = logger
host = logger1.example.com

# Logger 特定选项
logger_binary = /usr/local/zeek/bin/zeek
```

### 2.3 负载均衡方法

```ini
# lb_method 选项
lb_method = pf_ring           # PF_RING 负载均衡
lb_method = af_packet          # AF_PACKET 负载均衡
lb_method = custom             # 自定义脚本
lb_method = none              # 单 Worker，无负载均衡
```

---

## 3. cluster-layout.zeek 集群拓扑

`cluster-layout.zeek` 是 ZeekScript 脚本，定义集群的逻辑拓扑。

### 3.1 基础 cluster-layout.zeek

```zeek
# cluster-layout.zeek — 基础集群拓扑

@load base/frameworks/cluster

# 定义 Manager
redef Cluster::manager = {
    [$node_type = Cluster::MANAGER,
     $host = 192.168.1.10,
     $zone = "zeek-cluster"];
};

# 定义 Proxy（前端代理）
redef Cluster::proxies = {
    [$node_type = Cluster::PROXY,
     $host = 192.168.1.11,
     $p = 47761/tcp,
     $manager_host = 192.168.1.10],
    [$node_type = Cluster::PROXY,
     $host = 192.168.1.12,
     $p = 47761/tcp,
     $manager_host = 192.168.1.10]
};

# 定义 Logger
redef Cluster::loggers = {
    [$node_type = Cluster::LOGGER,
     $host = 192.168.1.13]
};

# 定义 Worker
redef Cluster::workers = {
    [$node_type = Cluster::WORKER,
     $host = 192.168.1.20,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4],
    [$node_type = Cluster::WORKER,
     $host = 192.168.1.21,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4],
    [$node_type = Cluster::WORKER,
     $host = 192.168.1.22,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4]
};
```

### 3.2 完整 cluster-layout.zeek

```zeek
# cluster-layout.zeek — 完整集群拓扑

@load base/frameworks/cluster
@load base/frameworks/broker

# ============ 集群名称 ============
redef Cluster::name = "production-cluster";

# ============ Manager ============
redef Cluster::manager = {
    [$node_type = Cluster::MANAGER,
     $ip = 192.168.1.10,
     $port = 47762/tcp,
     $zone = "prod"]
};

# ============ Proxy 配置 ============
redef Cluster::proxies = {
    # Proxy 节点 1
    [$node_type = Cluster::PROXY,
     $ip = 192.168.1.11,
     $port = 47761/tcp,
     $manager_ip = 192.168.1.10,
     $retry = 5sec],

    # Proxy 节点 2（HA）
    [$node_type = Cluster::PROXY,
     $ip = 192.168.1.12,
     $port = 47761/tcp,
     $manager_ip = 192.168.1.10,
     $retry = 5sec]
};

# ============ Logger 配置 ============
redef Cluster::loggers = {
    [$node_type = Cluster::LOGGER,
     $ip = 192.168.1.13,
     $manager_ip = 192.168.1.10],

    # 第二个 Logger（HA）
    [$node_type = Cluster::LOGGER,
     $ip = 192.168.1.14,
     $manager_ip = 192.168.1.10]
};

# ============ Worker 配置 ============
redef Cluster::workers = {
    # Worker 池 A - 10G 接口
    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.20,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4,
     $pin_cpus = {0, 1, 2, 3},
     $manager_ip = 192.168.1.10],

    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.21,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4,
     $pin_cpus = {4, 5, 6, 7},
     $manager_ip = 192.168.1.10],

    # Worker 池 B - 另一个 10G 接口
    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.22,
     $interface = "eth1",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4,
     $pin_cpus = {0, 1, 2, 3},
     $manager_ip = 192.168.1.10],

    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.23,
     $interface = "eth1",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 4,
     $pin_cpus = {4, 5, 6, 7},
     $manager_ip = 192.168.1.10]
};

# ============ 集群选项 ============
redef Cluster::sticky_response = Cluster::STICKY_RESPONSE_NONE;

# 流量分发策略
redef Cluster::dispatcher = Cluster::DISPATCHER_LOCAL;

# 状态同步间隔
redef Cluster::state_sync_interval = 10sec;

# 日志聚合
redef Cluster::enable_log_aggregation = T;

# 日志批量大小
redef Cluster::log_batch_size = 1000;
redef Cluster::log_batch_interval = 1sec;
```

### 3.3 Cluster::NodeType 定义

```zeek
# base/frameworks/cluster/main.zeek — 节点类型

module Cluster;

export {
    # 节点类型
    type NodeType: enum {
        MANAGER,    # Manager 节点
        PROXY,      # Proxy 节点
        LOGGER,     # Logger 节点
        WORKER      # Worker 节点
    };

    # 节点信息
    type Node: record {
        node_type: NodeType;      # 节点类型
        ip: addr;                 # IP 地址
        port: port &optional;     # 端口
        interface: string &optional;  # 接口名
        lb_method: string &optional; # 负载均衡方法
        lb_procs: count &optional;   # 进程数
        pin_cpus: set[count] &optional;  # CPU 亲和
        manager_ip: addr &optional;    # Manager IP
        zone: string &optional;        # 区域
    };

    # 负载均衡方法
    type LBMethod: enum {
        LB_METHOD_PF_RING,       # PF_RING 负载均衡
        LB_METHOD_AF_PACKET,     # AF_PACKET 负载均衡
        LB_METHOD_CUSTOM,        # 自定义
        LB_METHOD_NONE           # 无负载均衡
    };
}
```

---

## 4. 网络定义 networks.cfg

`networks.cfg` 定义本地网络，用于判断内外网地址。

### 4.1 networks.cfg 格式

```ini
# networks.cfg — 网络定义
# 格式: CIDR 描述

# 本地网络
10.0.0.0/8          Private IPV4
172.16.0.0/12       Private IPV4
192.168.0.0/16      Private IPV4

# 特殊网络
127.0.0.0/8         Loopback
169.254.0.0/16      Link-local

# 内部网络
10.10.0.0/16        Corporate Internal
10.20.0.0/16        DMZ
```

### 4.2 在脚本中使用

```zeek
# 使用 Site 模块判断地址类型
event http_request(c: connection, method: string, uri: string, version: string)
    {
    local orig = c$id$orig_h;
    local resp = c$id$resp_h;

    # 判断是否为内部/外部流量
    if (Site::is_private_addr(orig) && Site::is_private_addr(resp)) {
        print "internal traffic";
    } else if (Site::is_private_addr(orig)) {
        print "outbound traffic";
    } else if (Site::is_private_addr(resp)) {
        print "inbound traffic";
    } else {
        print "external traffic";
    }
    }
```

---

## 5. 流量分发配置

### 5.1 PF_RING 负载均衡

```ini
# node.cfg — PF_RING 配置
[worker-pf-ring]
type = worker
host = worker1.example.com
interface = eth0
lb_method = pf_ring
lb_procs = 8

# PF_RING 特定选项
lb_procs = 8                   # 启动 8 个 Worker 进程
pf_ring.interface = eth0       # 接口名
pf_ring.cluster_id = 99        # 集群 ID (1-255)
pf_ring.cluster_type = 3      # 负载均衡类型
                               # 1 = 5-tuple 哈希
                               # 2 = 2-tuple 哈希
                               # 3 = 4-tuple 哈希（默认）
```

```zeek
# cluster-layout.zeek — PF_RING 配置
redef Cluster::workers = {
    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.20,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_PF_RING,
     $lb_procs = 8,
     $pf_ring = [$cluster_id = 99, $cluster_type = 3]]
};
```

### 5.2 AF_PACKET 负载均衡

```ini
# node.cfg — AF_PACKET 配置
[worker-afpacket]
type = worker
host = worker1.example.com
interface = eth0
lb_method = af_packet
lb_procs = 4

# AF_PACKET 特定选项
af_packet_interface = eth0
af_packet_buffer_size = 65535
```

```zeek
# cluster-layout.zeek — AF_PACKET 配置
redef Cluster::workers = {
    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.20,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_AF_PACKET,
     $lb_procs = 4,
     $af_packet = [$buffer_size = 65535]]
};
```

### 5.3 自定义负载均衡

```zeek
# cluster-layout.zeek — 自定义负载均衡
redef Cluster::workers = {
    [$node_type = Cluster::WORKER,
     $ip = 192.168.1.20,
     $interface = "eth0",
     $lb_method = Cluster::LB_METHOD_CUSTOM,
     $custom = "my-lb-script"]
};
```

---

## 6. ZeekControl 命令

### 6.1 常用 zeekctl 命令

```bash
# 部署和启动
zeekctl deploy          # 部署配置并启动所有节点
zeekctl start           # 启动集群
zeekctl stop            # 停止集群
zeekctl restart         # 重启集群

# 节点管理
zeekctl status          # 查看集群状态
zeekctl status <node>   # 查看特定节点状态

# 日志查看
zeekctl log <node>      # 查看节点日志
zeekctl tail <node>     # 实时查看节点日志

# 配置检查
zeekctl check           # 检查配置语法
zeekctl diag <node>     # 节点诊断信息

# 滚动更新
zeekctl rolling-update  # 滚动更新集群

# 清理
zeekctl clean           # 清理临时文件
```

### 6.2 zeekctl 输出示例

```
$ zeekctl status

Cluster Status:
  manager    running (pid 12345)
  proxy-1   running (pid 12346)
  proxy-2   running (pid 12347)
  logger-1   running (pid 12348)
  worker-1   running (pid 12349-12352)
  worker-2   running (pid 12353-12356)
  worker-3   running (pid 12357-12360)

  There are 10 nodes running.
```

---

## 7. 集群脚本加载

### 7.1 脚本加载顺序

```
1. base/frameworks/cluster/main.zeek      # 集群框架主脚本
2. base/frameworks/cluster/state.zeek     # 状态管理
3. base/frameworks/cluster/log.zeek       # 日志聚合
4. site/cluster-layout.zeek              # 用户定义的集群拓扑
5. site/local.zeek                       # 本地站点配置
```

### 7.2 自定义集群脚本

```zeek
# site/my-cluster-scripts.zeek — 自定义集群脚本

@load base/frameworks/cluster

# 集群启动事件
event Cluster::node_up(node: Cluster::Node)
    {
    print fmt("Node up: %s (%s)", node$id, node$node_type);
    }

# 集群关闭事件
event Cluster::node_down(node: Cluster::Node)
    {
    print fmt("Node down: %s (%s)", node$id, node$node_type);
    }

# Worker 统计
event worker_stats(node_id: string, pkts: count, bytes: count)
    {
    print fmt("Worker %s: %d packets, %d bytes", node_id, pkts, bytes);
    }
```

---

## 8. 高级配置

### 8.1 Broker 网络配置

```zeek
# site/broker-network.zeek — Broker 网络配置

@load base/frameworks/broker

# 监听地址
redef Broker::default_port = 47761/tcp;

# 绑定地址
redef Broker::bind_address = "0.0.0.0";

# 广播地址（用于 NAT 环境）
redef Broker::advertised_address = "203.0.113.10";

# SSL 配置
redef Broker::enable_ssl = T;
redef Broker::ssl_cafile = "/etc/zeek/ssl/ca.pem";
redef Broker::ssl_certfile = "/etc/zeek/ssl/cert.pem";
redef Broker::ssl_keyfile = "/etc/zeek/ssl/key.pem";

# 缓冲区大小
redef Broker::max_pending_messages = 10000;
redef Broker::max_message_size = 1MB;

# 线程数
redef Broker::num_threads = 4;
```

### 8.2 日志聚合配置

```zeek
# site/log-aggregation.zeek — 日志聚合配置

@load base/frameworks/cluster

# 启用日志聚合
redef Cluster::enable_log_aggregation = T;

# 日志批量配置
redef Cluster::log_batch_size = 5000;
redef Cluster::log_batch_interval = 500msec;

# 日志过滤
redef Cluster::log_aggregation_filter = table {
    ["notice.log"] = T,
    ["weird.log"] = T,
    ["http.log"] = F,      # 不聚合 http.log
    ["dns.log"] = F,
};

# 日志缓冲
redef Cluster::log_buffer_size = 100000;
```

### 8.3 高可用配置

```zeek
# site/high-availability.zeek — 高可用配置

@load base/frameworks/cluster

# 心跳配置
redef Cluster::heartbeat_interval = 1sec;
redef Cluster::heartbeat_timeout = 30sec;

# 故障检测
redef Cluster::failure_detection_threshold = 3;

# 自动故障转移
redef Cluster::auto_failover = T;
redef Cluster::failover_retry_interval = 5sec;

# 状态同步
redef Cluster::state_sync_interval = 10sec;
redef Cluster::state_sync_max_rate = 1MB;
```

---

## 9. 配置验证

### 9.1 配置文件检查

```bash
# 检查 zeekctl 配置
$ zeekctl check
checking configurations ...

# 检查 cluster-layout.zeek
$ zeek -b scripts/site/cluster-layout.zeek
```

### 9.2 常见配置错误

```
错误 1: 节点类型未知
[worker-1]
type = workerer   # 拼写错误

错误 2: IP 地址格式错误
host = 192.168.1.256   # 无效 IP

错误 3: 端口格式错误
port = 47761           # 缺少 /tcp

错误 4: Manager 未定义
redef Cluster::manager = { ... };  # 缺少节点定义
```

---

## 10. 总结

本章介绍了 Zeek 集群配置的核心内容：

| 配置文件 | 用途 | 关键参数 |
|:---|:---|:---|
| `zeekctl.cfg` | ZeekControl 全局配置 | 日志路径、Broker 端口 |
| `node.cfg` | 节点配置 | type、host、interface |
| `cluster-layout.zeek` | 集群拓扑定义 | Manager/Proxy/Worker 定义 |
| `networks.cfg` | 网络定义 | CIDR 范围 |

下一章我们将深入讨论**集群通信**，包括 ZeekControl 协议、Broker 通信框架的实现细节。

---

> [!previous] 上一章：[[2026-04-15-zeek-deep-dive-ch25-cluster-arch|第二十五章：集群架构]]
> [!next] 下一章：[[2026-04-15-zeek-deep-dive-ch27-communication|第二十七章：通信]]
