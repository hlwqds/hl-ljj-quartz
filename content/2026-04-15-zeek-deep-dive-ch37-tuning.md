---
title: "Zeek 深度探索 (三十七)：Tuning 清单"
date: 2026-04-15
tags:
  - zeek
  - series
  - tuning
  - checklist
  - production
  - high-throughput
  - performance
description: "深入解析 Zeek 生产调优清单——系统内核参数、Zeek 配置、日志优化、集群调优、高吞吐量场景最佳实践、监控告警配置"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ... 35. [[2026-04-15-zeek-deep-dive-ch35-scripts|第三十五章：脚本优化]] 36. [[2026-04-15-zeek-deep-dive-ch36-hardware|第三十六章：硬件加速]] 37. **第三十七章：Tuning 清单**

---

## 1. 调优概述

本章汇总 Zeek 性能调优的最佳实践，提供可直接用于生产环境的配置清单。调优是一个迭代过程，建议按阶段逐步实施并验证效果。

```
┌─────────────────────────────────────────────────────────────┐
│                 调优实施流程                                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Phase 1: 基线测量                                         │
│  ├── 建立性能基准                                           │
│  ├── 识别当前瓶颈                                          │
│  └── 设置性能目标                                          │
│                           ↓                                  │
│  Phase 2: 系统级优化                                       │
│  ├── 内核参数调优                                          │
│  ├── 网络栈优化                                           │
│  └── 资源限制配置                                          │
│                           ↓                                  │
│  Phase 3: Zeek 配置优化                                    │
│  ├── Worker 配置                                           │
│  ├── 内存管理                                             │
│  └── 日志优化                                             │
│                           ↓                                  │
│  Phase 4: 持续监控                                        │
│  ├── 性能指标采集                                          │
│  ├── 告警配置                                             │
│  └── 定期评审                                             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

---

## 2. 系统级调优清单

### 2.1 内核参数 (sysctl)

```bash
# /etc/sysctl.d/99-zeek.conf

# =================== 网络内存参数 ===================
# 最大 socket 接收缓冲区
net.core.rmem_max = 16777216
net.core.rmem_default = 16777216

# 最大 socket 发送缓冲区
net.core.wmem_max = 16777216
net.core.wmem_default = 16777216

# TCP 内存参数（字节）
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# =================== 网络队列参数 ===================
# 网络设备积压队列长度
net.core.netdev_max_backlog = 50000

# 最大连接 backlog
net.core.somaxconn = 4096

# =================== TCP 参数 ===================
# 时间戳（关闭以减少处理开销）
net.ipv4.tcp_timestamps = 0

# SACK 选择性确认
net.ipv4.tcp_sack = 1

# TCP 窗口缩放
net.ipv4.tcp_window_scaling = 1

# =================== 虚拟内存参数 ===================
# 交换倾向（降低以减少 swap）
vm.swappiness = 10

# 脏页比例
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# =================== 文件系统参数 ===================
# 文件描述符上限
fs.file-max = 2097152

# inotify 限制
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512

# =================== 安全参数 ===================
# ICMP 重定向（安全考虑可关闭）
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
```

```bash
# 应用配置
sudo sysctl -p /etc/sysctl.d/99-zeek.conf

# 验证配置
sysctl net.core.rmem_max
sysctl net.core.wmem_max
sysctl net.core.netdev_max_backlog
```

### 2.2 用户资源限制 (limits.conf)

```bash
# /etc/security/limits.d/zeek.conf

# =================== 文件描述符 ===================
zeek soft nofile 1048576
zeek hard nofile 1048576

# =================== 进程数 ===================
zeek soft nproc 65536
zeek hard nproc 65536

# =================== 内存锁定 ===================
zeek soft memlock unlimited
zeek hard memlock unlimited

# =================== 核心转储（生产环境可限制） ===================
zeek soft core 0
zeek hard core 0
```

```bash
# 验证限制
ulimit -n
ulimit -u
ulimit -l
```

### 2.3 CPU 亲和性

```bash
# /etc/cron.d/zeek-cpuaffinity
# 设置 Zeek 进程 CPU 亲和性

# isolcpus 内核参数（引导时设置）
# GRUB_CMDLINE_LINUX="... isolcpus=0-7"

# 使用 systemd 设置亲和性
# /etc/systemd/system/zeek.service.d/cpu.conf
[Service]
CPUAffinity=0-7
```

### 2.4 网络设备优化

```bash
# /usr/local/bin/zeek-net-tuning.sh

#!/bin/bash
set -e

INTERFACE=${1:-eth0}

echo "Optimizing network interface: $INTERFACE"

# 禁用不需要的 offload
ethtool -K $INTERFACE rxvlan off txvlan off 2>/dev/null || true
ethtool -K $INTERFACE rx-checksum-ipv4 off tx-checksum-ipv4 off 2>/dev/null || true
ethtool -K $INTERFACE scatter-gather off 2>/dev/null || true
ethtool -K $INTERFACE tso off ufo off gso off 2>/dev/null || true

# 设置 ring buffer
ethtool -G $INTERFACE rx 4096 tx 4096

# 启用 RSS
ethtool -L $INTERFACE combined 8

# 设置中断亲和性（使用 irqbalance 或手动）
irqbalance --oneshot

echo "Network tuning complete"
```

```bash
# 添加到启动项
sudo chmod +x /usr/local/bin/zeek-net-tuning.sh
sudo ln -s /usr/local/bin/zeek-net-tuning.sh /etc/network/if-up.d/zeek-tuning
```

---

## 3. Zeek 配置调优清单

### 3.1 zeekctl.cfg

```ini
# /usr/local/zeek/etc/zeekctl.cfg

[logger]
# 日志写入模式
send_report = 0
logdir = /var/log/zeek

[worker]
# Worker 进程数量（建议: CPU 核心数 - 1）
lb_procs = 7

# 日志写入模式
log_stream_interval = 60

# 事件处理
max_events_in_queue = 10000

# 内存限制
max_memory = 8GB

# CPU 亲和性
pin = true

[proxy]
# Proxy 进程数量（建议: 1-2）
lb_procs = 1
```

### 3.2 node.cfg

```ini
# /usr/local/zeek/etc/node.cfg

[worker-1]
type = worker
host = localhost
interface = eth0
lb_procs = 4
pin_cpus = 0,1,2,3

[worker-2]
type = worker
host = localhost
interface = eth0
lb_procs = 4
pin_cpus = 4,5,6,7

[proxy-1]
type = proxy
host = localhost
```

### 3.3 Zeek 脚本调优

```zeek
# /usr/local/zeek/share/zeek/site/local.zeek

# =================== 内存优化 ===================
# 连接状态表大小
redef max_connection_state = 1000000;

# DNS 缓存大小
redef dns_cache_size = 100000;
redef dns_ttl_uid_cache_size = 100000;

# =================== 事件队列 ===================
# 事件队列大小
redef event_queue_size = 50000;

# 事件丢弃阈值
redef event_dropped_threshold = 0.8;

# =================== 协议解析 ===================
# 最大分析深度
redef analyzer_max_depth = 5;

# 文件提取限制
redef file_extract_total_size_limit = 1GB;
redef extract_file_size_limit = 100MB;

# =================== 日志优化 ===================
# 日志缓冲大小
redef log_buffer_size = 8MB;

# 异步日志写入
redef log_write_buffer_size = 8192;

# JSON 日志压缩
redef Log::default_rotation_interval = 1hr;

# =================== Profiling ===================
# 性能分析（生产环境可关闭）
@if ( Cluster::node != "worker" )
@load tuning/profiling
redef profiling_interval = 5mins;
@endif
```

### 3.4 脚本级优化

```zeek
# =================== 热点优化 ===================
# 减少不必要的事件处理
event zeek_init() {
    # 仅在必要时启用详细日志
    if ( Cluster::node == "manager" ) {
        Log::default_level = INFO;
    } else {
        Log::default_level = WARN;
    }
}

# =================== 定时器优化 ===================
# 减少定时器数量
redef default_connection_timeout = 5mins;
redef tcp_inactivity_timeout = 5mins;
redef udp_inactivity_timeout = 1min;

# =================== 表大小限制 ===================
# 防止表无限增长
global known_hosts_max_size = 1000000;
global known_services_max_size = 500000;
```

---

## 4. 日志调优清单

### 4.1 日志输出配置

```zeek
# /usr/local/zeek/share/zeek/site/logging.zeek

# =================== 日志 Writers ===================
# 使用 JSON 格式（便于 SIEM 集成）
@if ( zeek_version() >= 60000 )
redef Log::default_writer = Log::WRITER_JSON;
@endif

# =================== 日志轮转 ===================
# 文件轮转大小
redef Log::default_rotation_size_limit = 250MB;

# 轮转间隔
redef Log::default_rotation_interval = 1hr;

# =================== 日志过滤 ===================
# 禁用不必要的日志
event zeek_init() {
    # 禁用 SSH 详细日志（如果不需要）
    # Log::disable_stream(SSH::LOG);

    # 禁用 FTP 详细日志
    # Log::disable_stream(FTP::LOG);
}
```

### 4.2 高吞吐量日志配置

```zeek
# /usr/local/zeek/share/zeek/site/high-throughput-logging.zeek

# 使用异步日志写入
redef log_asynchronous_writer = T;

# 批量写入
redef log_write_buffer_size = 16384;

# 合并小文件写入
redef log_merge_interval = 5secs;

# 压缩历史日志
redef log_compression = "gzip";
```

### 4.3 日志输出目标

```zeek
# 输出到多个目标

# 1. 本地文件
redef Log::default_log_dir = "/var/log/zeek";

# 2. Kafka（高吞吐量场景）
@load policy/frameworks/logging/writers/kafka

redef Kafka::logging_kafka_topic = "zeek-logs";
redef Kafka::logging_kafka_brokers = set("kafka1:9092", "kafka2:9092");

# 3. Redis（低延迟场景）
@load policy/frameworks/logging/writers/redis

redef LogRedis::redis_host = "127.0.0.1";
redef LogRedis::redis_port = 6379/tcp;
```

---

## 5. 集群调优清单

### 5.1 集群架构配置

```zeek
# /usr/local/zeek/share/zeek/site/cluster.zeek

@load base/frameworks/cluster

redef Cluster::nodes = {
    # Manager 节点
    ["manager"] = [
        $node_type = Cluster::MANAGER,
        $ip = 127.0.0.1,
        $p = 47761/tcp
    ],

    # Proxy 节点
    ["proxy-1"] = [
        $node_type = Cluster::PROXY,
        $ip = 127.0.0.1,
        $manager = "manager",
        $p = 47762/tcp
    ],

    # Logger 节点
    ["logger-1"] = [
        $node_type = Cluster::LOGGER,
        $ip = 127.0.0.1,
        $manager = "manager"
    ],

    # Worker 节点（多个）
    ["worker-1"] = [
        $node_type = Cluster::WORKER,
        $ip = 127.0.0.1,
        $interface = "eth0",
        $lb_procs = 4,
        $pin_cpus = {0, 1, 2, 3},
        $proxy = "proxy-1"
    ],

    ["worker-2"] = [
        $node_type = Cluster::WORKER,
        $ip = 127.0.0.1,
        $interface = "eth0",
        $lb_procs = 4,
        $pin_cpus = {4, 5, 6, 7},
        $proxy = "proxy-1"
    ],
};
```

### 5.2 集群通信优化

```zeek
# 通信缓冲区大小
redef Cluster::buffer_size = 10000;

# 通信超时
redef Cluster::comm_timeout = 1min;

# 批量消息
redef Cluster::max_batch_size = 1000;
```

### 5.3 负载均衡配置

```zeek
# /usr/local/zeek/share/zeek/site/load-balancing.zeek

@load policy/frameworks/load-management

# 使用 Flow 哈希
redef LoadManagement::lb_method = "flow";

# Flow 哈希参数
redef LoadManagement::flow_hash_ports = T;
redef LoadManagement::flow_hash_ips_only = F;
```

---

## 6. 高吞吐量场景配置

### 6.1 10Gbps+ 场景配置

```bash
# /usr/local/zeek/etc/zeekctl.cfg (高吞吐量)
[worker]
lb_procs = 16
max_memory = 16GB
pin = true
```

```zeek
# /usr/local/zeek/share/zeek/site/high-throughput.zeek

# 事件队列（扩大以应对突发）
redef event_queue_size = 100000;

# 连接表（支持更多并发连接）
redef max_connection_state = 5000000;

# DNS 缓存
redef dns_cache_size = 500000;

# 禁用不必要的分析器
event zeek_init() {
    # 如果不需要 SMTP 分析
    # Analyzer::disable(Analyzer::ANALYZER_SMTP);

    # 如果不需要 RDP 分析
    # Analyzer::disable(Analyzer::ANALYZER_RDP);
}

# 采样（可选，超高吞吐量时）
redef sampling_filter = "ip[2:2] > 100";
```

### 6.2 采样配置

```zeek
# /usr/local/zeek/share/zeek/site/sampling.zeek

# 随机采样（处理 1/10 的流量）
redef sampling_probability = 0.1;

# 基于流量大小的采样
redef sample_larger_flows = T;
redef large_flow_threshold = 10MB;

# 条件采样
redef sampling_filter = "not (tcp[((tcp[12:1] & 0xf0) >> 2):2] = 80)";
```

### 6.3 流量过滤

```zeek
# /usr/local/zeek/share/zeek/site/packet-filter.zeek

# 提前过滤不需要的流量
@load base/frameworks/packet-filter

# 只分析特定子网
redef PacketFilter::filter = "net 10.0.0.0/8 or net 192.168.0.0/16";

# 排除已知的非关注流量
redef PacketFilter::exceptions = "10.0.0.0/8,192.168.0.0/16";
```

---

## 7. 监控与告警清单

### 7.1 性能监控脚本

```bash
#!/bin/bash
# /usr/local/bin/zeek-monitor.sh

LOG_DIR="/var/log/zeek"
STATS_FILE="$LOG_DIR/stats.log"

monitor_zeek() {
    local pid=$(pidof zeek)
    if [ -z "$pid" ]; then
        echo "Zeek not running"
        return 1
    fi

    # 内存使用
    local mem=$(ps -o rss= -p $pid | awk '{print $1/1024}')

    # CPU 使用
    local cpu=$(ps -o %cpu= -p $pid)

    # 连接数
    local conns=$(wc -l < $LOG_DIR/conn.log 2>/dev/null || echo 0)

    # 丢包率
    local loss=$(grep -a "^#fields" $LOG_DIR/capture_loss.log 2>/dev/null && \
                 awk 'END {if(NR>1) print}' $LOG_DIR/capture_loss.log 2>/dev/null | \
                 awk '{print $4/$2}' 2>/dev/null || echo "N/A")

    echo "$(date '+%Y-%m-%d %H:%M:%S') Memory=${mem}MB CPU=${cpu}% Conn=${conns} Loss=${loss}"
}

# 持续监控
while true; do
    monitor_zeek >> $STATS_FILE
    sleep 60
done
```

### 7.2 Prometheus 监控配置

```zeek
# /usr/local/zeek/share/zeek/site/prometheus.zeek

@load base/misc/perfstats

module PrometheusExporter;

export {
    global listen_addr = "0.0.0.0";
    global listen_port = 9091/tcp;
}

event zeek_init() {
    Broker::listen(listen_addr, listen_port);
}

event perf_stats_update(s: perfstats) {
    local metrics = vector(
        fmt("# HELP zeek_memory_rss_bytes Zeek RSS memory in bytes"),
        fmt("# TYPE zeek_memory_rss_bytes gauge"),
        fmt("zeek_memory_rss_bytes %.0f", s$mem),

        fmt("# HELP zeek_events_processed_total Total events processed"),
        fmt("# TYPE zeek_events_processed_total counter"),
        fmt("zeek_events_processed_total %.0f", s$events),

        fmt("# HELP zeek_packets_processed_total Total packets processed"),
        fmt("# TYPE zeek_packets_processed_total counter"),
        fmt("zeek_packets_processed_total %.0f", s$pkts)
    );

    for ( m in metrics ) {
        print m;
    }
}
```

```yaml
# prometheus.yml 配置
scrape_configs:
  - job_name: "zeek"
    static_configs:
      - targets: ["zeek-node:9091"]
    scrape_interval: 15s
```

### 7.3 告警阈值

```zeek
# /usr/local/zeek/share/zeek/site/alerts.zeek

module AlertThresholds;

export {
    # 内存告警阈值
    global memory_warning_threshold = 8GB;
    global memory_critical_threshold = 12GB;

    # CPU 告警阈值
    global cpu_warning_threshold = 80.0;
    global cpu_critical_threshold = 95.0;

    # 丢包告警阈值
    global packet_loss_warning = 0.001;   # 0.1%
    global packet_loss_critical = 0.01;   # 1%

    # 事件队列告警阈值
    global event_queue_warning = 50000;
    global event_queue_critical = 100000;
}

event memory_update(s: memory_stats) {
    if ( s$mem > memory_critical_threshold ) {
        Reporter::error("Critical: Zeek memory exceeded critical threshold");
    } else if ( s$mem > memory_warning_threshold ) {
        Reporter::warning("Warning: Zeek memory exceeded warning threshold");
    }
}

event capture_loss_update(u: count, d: count, i: count) {
    local loss_rate = double(d) / double(u + d);

    if ( loss_rate > packet_loss_critical ) {
        Reporter::error(fmt("Critical packet loss: %.2f%%", loss_rate * 100));
    } else if ( loss_rate > packet_loss_warning ) {
        Reporter::warning(fmt("Warning packet loss: %.2f%%", loss_rate * 100));
    }
}
```

---

## 8. 生产环境检查清单

### 8.1 部署前检查

```bash
# =================== 系统检查 ===================
# [ ] CPU 核心数 >= 8
nproc

# [ ] 内存 >= 32GB
free -h

# [ ] 磁盘空间充足（建议 >= 100GB）
df -h

# [ ] 网卡支持多队列
ethtool -l eth0

# =================== 内核参数 ===================
# [ ] sysctl 参数已应用
sysctl net.core.rmem_max
# 预期: 16777216

# [ ] 文件描述符限制
ulimit -n
# 预期: >= 1048576

# =================== Zeek 安装 ===================
# [ ] Zeek 版本
zeek --version

# [ ] Zeek 依赖库
ldd $(which zeek) | grep "not found"

# [ ] 脚本语法检查
zeek -x /usr/local/zeek/share/zeek/site/local.zeek
```

### 8.2 启动验证

```bash
# =================== 启动检查 ===================
# [ ] Zeek 启动成功
systemctl status zeek

# [ ] 进程运行正常
ps aux | grep zeek

# [ ] 端口监听正常
netstat -tlnp | grep zeek

# =================== 功能检查 ===================
# [ ] 连接日志生成
tail -f /var/log/zeek/conn.log

# [ ] DNS 日志生成
tail -f /var/log/zeek/dns.log

# [ ] HTTP 日志生成
tail -f /var/log/zeek/http.log

# [ ] 无丢包
grep -a "drops" /var/log/zeek/capture_loss.log
```

### 8.3 性能基线

```bash
# 建立性能基线
# 1. 处理速率
#    预期: >= 100K packets/sec (per worker)

# 2. 内存使用
#    预期: <= 8GB per worker

# 3. CPU 使用
#    预期: <= 70% per worker

# 4. 事件队列深度
#    预期: <= 1000

# 5. 丢包率
#    预期: < 0.01%
```

---

## 9. 故障排查清单

### 9.1 常见问题与解决方案

| 问题              | 可能原因                      | 解决方案                      |
| :---------------- | :---------------------------- | :---------------------------- |
| **Zeek 无法启动** | 端口被占用                    | `netstat -tlnp \| grep 47760` |
| **丢包严重**      | RSS 未配置 / Ring buffer 太小 | 配置 RSS / 增加 ring buffer   |
| **内存持续增长**  | 内存泄漏                      | 检查 DNS 缓存 / 全局表        |
| **CPU 100%**      | 正则表达式回溯                | 简化正则 / 使用 re2           |
| **事件队列积压**  | 处理速度慢                    | 优化脚本 / 增加 worker        |
| **日志不输出**    | 权限问题 / 磁盘满             | 检查权限 / 清理磁盘           |
| **集群通信失败**  | 防火墙 / 网络                 | 检查端口 / 防火墙规则         |

### 9.2 诊断命令速查

```bash
# 查看 Zeek 进程
ps aux | grep zeek

# 查看线程数
ps -T -p $(pidof zeek) | wc -l

# 查看打开的文件
lsof -p $(pidof zeek) | wc -l

# 查看网络连接
ss -tnap | grep zeek

# 查看内存映射
cat /proc/$(pidof zeek)/maps | wc -l

# 查看系统日志
journalctl -u zeek -n 50

# 查看 dmesg（内核日志）
dmesg | tail -20

# 网络统计
netstat -s | grep -i error
netstat -s | grep -i drop
```

---

## 10. 定期维护清单

### 10.1 日常检查

```bash
# =================== 每日 ===================
# [ ] 检查 Zeek 进程是否运行
systemctl status zeek

# [ ] 检查磁盘空间
df -h /var/log/zeek

# [ ] 检查最新日志
tail -100 /var/log/zeek/conn.log

# [ ] 检查告警
grep -i "warning\|error" /var/log/zeek/zeek.log
```

### 10.2 每周检查

```bash
# =================== 每周 ===================
# [ ] 分析性能趋势
cat /var/log/zeek/stats.log | tail -10080 > /tmp/weekly-stats.txt

# [ ] 检查日志轮转
ls -lh /var/log/zeek/*.log.*

# [ ] 清理旧日志
find /var/log/zeek -name "*.log.*" -mtime +30 -delete

# [ ] 更新 Zeek（如需要）
# zeek --version && zeek-update
```

### 10.3 季度检查

```bash
# =================== 季度 ===================
# [ ] 审查性能基线
# [ ] 评估硬件容量
# [ ] 更新 Zeek 版本
# [ ] 审查安全补丁
# [ ] 备份配置文件
```
