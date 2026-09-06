---
title: "Zeek 深度探索 Ch41：Zeek 集群架构与分布式部署"
date: 2026-04-15
tags: [zeek, series, cluster, distributed]
description: "Zeek 集群架构详解：Manager/Proxy/Worker 角色、流量分发策略、高可用部署"
---

# Zeek 深度探索 Ch41：Zeek 集群架构与分布式部署

## 概述

当网络流量超过单台Zeek节点的处理能力时，需要部署Zeek集群来横向扩展流量处理能力。Zeek集群采用分布式架构，将流量分发到多个worker节点并行处理，实现高吞吐量和高可用性。

## Zeek集群架构

### 核心组件

```
                    +------------------+
                    |     Manager      |
                    | (日志聚合/控制)   |
                    +--------+---------+
                             |
            +----------------+----------------+
            |                |                |
    +-------+--------+ +------+------+ +------+
    |   Proxy-1      | |   Proxy-2    | | Proxy-3
    +-------+--------+ +------+------+ +------+
            |                |                |
    +-------+--------+ +------+------+ +------+
    |   Worker-1     | |   Worker-2   | | Worker-3
    |  (流量分析)     | |  (流量分析)   | |  (流量分析)
    +----------------+ +--------------+ +------+
```

#### Manager节点

Manager是集群的控制中心，负责：

- 协调所有节点的操作
- 聚合来自worker的日志
- 存储和转发日志到最终目的地
- 运行clusterController和topk算法

#### Proxy节点

Proxy作为worker与manager之间的中间层：

- 聚合来自多个worker的事件流
- 减少manager的连接压力
- 实现负载均衡
- 维护集群状态

#### Worker节点

Worker执行实际的流量分析：

- 捕获和处理网络流量
- 生成安全事件
- 将日志发送给proxy或直接到manager
- 运行协议分析器

### 集群配置文件

#### node.cfg - 节点定义

```ini
# Manager节点配置
[manager]
type=manager
host=192.168.1.10
port=47760

# Proxy节点配置
[proxy-1]
type=proxy
host=192.168.1.11
port=47761

[proxy-2]
type=proxy
host=192.168.1.12
port=47762

# Worker节点配置
[worker-1]
type=worker
host=192.168.1.13
lan_intf=eth0
port=47763

[worker-2]
type=worker
host=192.168.1.14
lan_intf=eth0
port=47764
```

#### zeekctl.cfg - 集群控制配置

```ini
[zeek]
host=192.168.1.10
site_scripts=/opt/zeek/share/site
zeek_port=47760

[logger]
# 可选：独立的logger节点
enabled=false

[worker]
# Worker资源限制
parosize=512
max磁盘空间使用百分比
# ...
```

### 流量分发策略

#### PF_RING分散

使用PF_RING的cluster pool模式分散流量：

```bash
# 在worker启动脚本中配置
zeek -i eth0 -U unoptimized \
    -p /opt/zeek/lib/broker/zeek brokerage \
    Cluster::enable_detection_logic=T \
    Cluster::worker_pool=cluster
```

#### 哈希分散

基于五元组哈希分发流量：

```bash
# 使用ip hash分散
ip link set eth0 type virtio_net hashmax 4096
```

## 集群部署实践

### 环境准备

#### 安装依赖

```bash
# 所有节点安装
apt-get update
apt-get install -y zeek zeekctl
apt-get install -y make gcc g++ libpcap-dev
apt-get install -y python3 python3-pip

# 节点间SSH无密码访问
ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa
ssh-copy-id zeek@192.168.1.11
ssh-copy-id zeek@192.168.1.12
```

#### 网络配置

```bash
# 所有节点配置
cat >> /etc/hosts << EOF
192.168.1.10  manager
192.168.1.11  proxy-1
192.168.1.12  proxy-2
192.168.1.13  worker-1
192.168.1.14  worker-2
EOF
```

### Zeek集群配置

#### 配置步骤

```bash
# 1. 编辑node.cfg
cat > /opt/zeek/etc/node.cfg << 'EOF'
[manager]
type=manager
host=192.168.1.10
port=47760

[proxy-1]
type=proxy
host=192.168.1.11

[worker-1]
type=worker
host=192.168.1.13
interface=eth0

[worker-2]
type=worker
host=192.168.1.14
interface=eth0
EOF

# 2. 验证配置
zeekctl deploy

# 3. 检查集群状态
zeekctl status
```

#### 集群启动和停止

```bash
# 启动集群
zeekctl start

# 停止集群
zeekctl stop

# 重启特定节点
zeekctl restart worker-1

# 查看所有节点日志
zeekctl logs
```

### 集群管理

#### 监控集群状态

```bash
# 查看集群状态
$ zeekctl status
cluster started
manager      running   (pid 12345)
proxy-1      running   (pid 12346)
worker-1     running   (pid 12347)
worker-2     running   (pid 12348)

# 查看实时日志
zeekctl tail

# 查看特定节点
zeekctl status worker-1
```

#### 动态扩展Worker

```bash
# 添加新的worker节点
# 1. 编辑node.cfg添加新节点
echo "[worker-3]" >> /opt/zeek/etc/node.cfg
echo "type=worker" >> /opt/zeek/etc/node.cfg
echo "host=192.168.1.15" >> /opt/zeek/etc/node.cfg
echo "interface=eth0" >> /opt/zeek/etc/node.cfg

# 2. 部署新配置
zeekctl deploy

# 3. 确认新节点运行
zeekctl status
```

### 日志聚合

#### 本地日志聚合

```bash
# 配置manager聚合所有日志
# zeekctl.cfg
[manager]
log_dir=/var/log/zeek
```

#### 远程日志转发

使用Syslog进行远程日志转发：

```zeek
# local.zeek中添加
event zeek_init() {
    Log::enable_remote_host(':516);
}
```

使用Elasticsearch输出：

```zeek
@load plugins/elasticsearch
event zeek_init() {
    Elasticsearch::connect([
        $host=127.0.0.1,
        $port=9200,
        $stream_prefix="zeek"
    ]);
}
```

## 高可用性配置

### 故障转移

#### Manager故障转移

```bash
# 配置备用的manager节点
# node.cfg
[manager]
type=manager
host=192.168.1.10
port=47760

[manager-backup]
type=manager
host=192.168.1.20
port=47760
```

#### Proxy负载均衡

```bash
# 配置多个proxy进行负载均衡
[proxy-1]
type=proxy
host=192.168.1.11

[proxy-2]
type=proxy
host=192.168.1.12

# Worker配置使用proxy列表
[worker-1]
type=worker
host=192.168.1.13
proxy=192.168.1.11,192.168.1.12
```

### 健康检查

#### 自动故障检测

```bash
# zeekctl.cfg中配置健康检查
[health_check]
# 检测间隔（秒）
interval=30

# 不响应的阈值
max_tries=3

# 等待时间（秒）
timeout=10
```

## 性能调优

### Worker性能配置

```ini
# node.cfg - Worker优化
[worker-1]
type=worker
host=192.168.1.13
interface=eth0
pin=0
max磁盘空间=80%

# 启用优化模式
env_vars=ZEEKPATH=/opt/zeek
```

### 流量分散策略

#### 基于接口的流量分散

```bash
# 每个worker监听不同接口
# worker-1: eth0 (入站流量)
# worker-2: eth1 (出站流量)
# worker-3: eth2 (混合流量)
```

#### 基于哈希的流量分散

```bash
# 使用tc命令配置流量哈希分散
tc qdisc add dev eth0 clsact
tc filter add dev eth0 egress match \
    "cmp(u16 at 2 layer network mask 0ffff) gt 0" \
    action skbedit setucid 1:1
```

## 故障排查

### 常见问题

#### 节点无法连接

```bash
# 检查网络连通性
ping manager
nc -zv manager 47760

# 检查Zeek进程
ps aux | grep zeek
```

#### 流量分散不均

```bash
# 检查worker日志
zeekctl logs worker-1

# 查看流量统计
cat /var/log/zeek/stats.log
```

### 日志分析

```bash
# 查看manager日志
tail -f /var/log/zeek/manager.log

# 查看worker日志
tail -f /var/log/zeek/worker-1.log

# 查看通信日志
tail -f /var/log/zeek/comm.log
```

## 最佳实践

1. **节点规格**：Worker节点CPU核心数越多越好，内存建议64GB+
2. **网络配置**：使用千兆或万兆网卡，启用网卡的flow director功能
3. **存储配置**：日志存储使用SSD，网络分割使用专用网卡
4. **监控告警**：配置节点失联告警，磁盘空间告警
5. **定期维护**：定期检查集群健康状态，更新Zeek版本

## 总结

Zeek集群架构通过分布式处理实现了大规模网络流量的高性能分析。理解集群的各个组件及其交互方式，合理配置流量分散策略，是成功部署Zeek集群的关键。随着网络规模的增长，可以通过简单地添加更多worker节点来实现线性扩展。
