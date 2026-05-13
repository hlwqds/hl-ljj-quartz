---
title: "Zeek 深度探索 Ch43：Zeek 性能调优"
date: 2026-04-15
tags: [zeek, series, performance, tuning]
description: "Zeek 性能调优：内核参数、内存/CPU优化、PF_RING、BPF过滤器"
---

# Zeek 深度探索 Ch43：Zeek 性能调优

## 概述

Zeek在大规模网络环境中处理高吞吐量流量时，性能优化至关重要。本章介绍系统级优化、Zeek配置调优和脚本级性能最佳实践。

## 系统级优化

### 内核参数调优

```bash
# /etc/sysctl.conf - 网络内核参数

# 增加网络缓冲区
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=16777216
net.core.wmem_default=16777216
net.core.netdev_max_backlog=50000
net.core.somaxconn=4096

# 增加IP协议参数
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.ipv4.tcp_max_syn_backlog=8192

# 启用TIME_WAIT重用
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15

# 增加文件描述符限制
fs.file-max=655360

# 应用配置
sysctl -p
```

### 文件描述符限制

```bash
# /etc/security/limits.conf
zeek        soft    nofile          655360
zeek        hard    nofile          655360
zeek        soft    nproc           65536
zeek        hard    nproc           65536

# 永久生效需要编辑 /etc/pam.d/common-session*
```

### 网络接口优化

```bash
# 启用网卡的RSS (Receive Side Scaling)
ethtool -K eth0 rxhash on
ethtool -K eth0 gro on
ethtool -K eth0 gso on

# 设置Ring Buffer大小
ethtool -G eth0 rx 4096 tx 4096

# 查看当前设置
ethtool -g eth0
ethtool -l eth0
```

### PF_RING配置

```bash
# 安装PF_RING
apt-get install -y pf-ring

# 加载PF_RING模块
modprobe pf_ring

# 配置Zeek使用PF_RING
cat >> /opt/zeek/etc/zeekctl.cfg << 'EOF'
pf_ring=true
pf_ring_interface=eth0
pf_ring_clusterid=12345
EOF
```

## Zeek配置优化

### zeekctl.cfg优化

```ini
# /opt/zeek/etc/zeekctl.cfg

[zeek]
# 优化Zeek运行时参数
max_disk_space=80%
max_maintenance_time=60
checkpoint_interval=300

[worker]
# Worker进程优化
max磁盘空间=80%
parosize=512
num_workers=4
# 启用优化模式
optimization_mode=aggressive
# 禁用的协议分析器
disable_interpreters=
# 启用统计信息收集
enable_stats=T
```

### 协议分析器管理

```bash
# 查看已加载的协议分析器
zeek -N | grep -i analyzer | head -20

# 禁用不需要的分析器
# local.zeek
@load-skip protocols/ftp
@load-skip protocols/irdp
@load-skip protocols/netbios
@load-skip protocols/ntp
@load-skip protocols.radius
@load-skip protocols/rdp
@load-skip protocols/sip
```

### 脚本优化

#### 禁用不必要的日志

```zeek
# local.zeek - 禁用不需要的日志
Log::disable_stream(Conn::LOG);
Log::disable_stream(DNS::LOG);
Log::disable_stream(HTTP::LOG);

# 只保留必要的日志
Log::enable_stream(Weird::LOG);
Log::enable_stream(Notice::LOG);
```

#### 调整日志输出

```zeek
# 调整日志过滤
Log::remove_filter(HTTP::LOG, "default");

Log::add_filter(HTTP::LOG, [
    $name="performance-filter",
    $pred(h: HTTP::Info) = {
        # 只记录可疑的HTTP流量
        return h$status_code >= 400 || h$method == "POST";
    }
]);
```

## 内存优化

### 内存配置

```bash
# 设置Zeek内存限制
# /etc/security/limits.conf
zeek     soft    memlock         unlimited
zeek     hard    memlock         unlimited

# 使用memory.zeek调整内存分配
@load tuning/memory
```

### 内存分析

```zeek
# 监控内存使用
global memory_samples: vector of count;

event memory_profile() {
    local usage = memory_usage();
    memory_samples += usage$total;

    if (|memory_samples| > 60) {
        local avg = 0;
        for (s in memory_samples) {
            avg += s;
        }
        avg = avg / |memory_samples|;
        print fmt("Average memory: %s MB", avg / 1024 / 1024);
    }

    schedule 60 secs { memory_profile() };
}

event zeek_init() {
    schedule 60 secs { memory_profile() };
}
```

### 连接跟踪优化

```zeek
# 调整连接表大小
redef record connection += {
    local_timeout: interval &optional;
};

# 缩短连接超时
redef connection_timeout = 10 mins;

# 清理不活跃连接
event connection_state_remove(c: connection) {
    if (c$duration < 5 secs) {
        # 快速清理短连接
    }
}
```

## CPU优化

### 多进程配置

```bash
# 使用单进程多线程模式
# zeekctl.cfg
[worker]
num_workers=8
```

### 禁用调试输出

```zeek
# local.zeek - 禁用所有print语句
redef enable_print = F;

# 禁用脚本调试
@unload tuning/track-memeory.zeek
@unload tuning/load-scaling.zeek
```

### 脚本执行优化

```zeek
# 不推荐：每个包都处理
event packet(c: connection) {
    process_packet(c);
}

# 推荐：批量处理
event packet_batch(batch: packet[]) {
    for (p in batch) {
        process_packet(p);
    }
}
```

## 存储优化

### 日志轮转配置

```ini
# /opt/zeek/etc/zeekctl.cfg
log_archive_interval=3600
log_rotation_size_limit=1073741824  # 1GB
log_max_size_default=10737418240     # 10GB
```

### 日志压缩

```bash
# 启用日志压缩
# local.zeek
Log::default_rotation_interval = 1 day;
Log::default_rotation_limit = 1 GB;

# 配置日志压缩
redef Log::default_out_fifo = "/var/log/zeek";
```

### 日志文件系统

```bash
# 使用适合大量小文件的文件系统
# /etc/fstab
UUID=xxx /var/log/zeek ext4 noatime,nodiratime,errors=remount-ro 0 2

# 或者使用XFS
/dev/sdb1 /var/log/zeek xfs noatime,logbufs=8 0 2
```

## 高吞吐量优化

### 流量采样

```zeek
# 对高流量场景进行采样
global packet_count: count = 0;
global sample_rate = 100;  # 每100个包采样1个

event packet(c: connection) {
    packet_count += 1;

    if (packet_count % sample_rate == 0) {
        process_packet(c);
    }
}
```

### 分布式处理

```bash
# 使用PF_RING分散
# worker配置
pf_ring_mode=cluster
pf_ring_cluster_type=5tuple

# 或者使用AF_PACKET
af_packet_mode=fanout
af_packet_group=0
```

### BPF过滤器优化

```bash
# 只捕获感兴趣的流量
zeek -i eth0 "tcp port 80 or tcp port 443 or tcp port 22"

# 排除已知的大流量源
zeek -i eth0 "not (host 192.168.1.100 and port 80)"
```

## 性能监控

### 内置统计信息

```bash
# 查看Zeek统计信息
zeekctl stats

# 实时统计
watch -n 1 "zeekctl stats"

# 查看进程状态
ps aux | grep zeek
```

### 自定义性能指标

```zeek
# 创建性能日志
module Performance;

export {
    global perf_log: Log::Stream;
}

type PerfInfo: record {
    ts: time;
    packets_processed: count;
    bytes_processed: count;
    dropped_packets: count;
    cpu_usage: double;
    memory_usage: count;
};

event packet_in(c: connection) {
    # 记录性能指标
}
```

### 外部监控集成

```bash
# 使用Prometheus监控
# 安装 exporter
pip install zeek_prometheus_exporter

# 配置导出器
zeek_exporter --listen :9313
```

## 瓶颈诊断

### CPU瓶颈

```bash
# 使用top分析CPU使用
top -Hp $(pgrep -f "zeek")

# 使用perf分析
perf top -p $(pgrep -f "zeek")
```

### 内存瓶颈

```bash
# 检查内存使用
cat /proc/$(pgrep -f "zeek")/status | grep -i vm

# 使用valgrind分析内存泄漏
valgrind --tool=memcheck zeek
```

### 网络瓶颈

```bash
# 检查丢包
netstat -s | grep -i error
netstat -s | grep -i drop

# 使用ethtool查看网卡统计
ethtool -S eth0
```

### 磁盘I/O瓶颈

```bash
# 检查磁盘I/O
iostat -x 1

# 检查磁盘空间
df -h
du -sh /var/log/zeek/*
```

## 优化清单

### 系统层面

- [ ] 内核参数已优化
- [ ] 文件描述符限制已提高
- [ ] 网卡RSS/GRO已启用
- [ ] PF_RING或AF_PACKET已配置

### Zeek配置

- [ ] 只加载需要的协议分析器
- [ ] 不需要的日志已禁用
- [ ] 日志轮转已配置
- [ ] 内存限制已设置

### 脚本层面

- [ ] print语句已移除或禁用
- [ ] 使用批量处理代替单事件处理
- [ ] 使用BPF过滤器减少流量
- [ ] 不活跃的连接超时已优化

## 常见问题

### 丢包严重

```bash
# 1. 检查网卡统计
ethtool -S eth0 | grep -i drop

# 2. 增加Ring Buffer
ethtool -G eth0 rx 8192 tx 8192

# 3. 增加worker数量
# node.cfg
[worker]
num_workers=16
```

### 内存持续增长

```zeek
# 1. 检查连接表是否正常清理
# 2. 检查是否有内存泄漏
@load tuning/track-memeory.zeek

# 3. 设置内存限制
redef max_memory = 8 GB;
```

### CPU使用率高

```bash
# 1. 检查是否有过多的协议分析器
zeek -N | wc -l

# 2. 禁用不需要的分析器
# local.zeek
@load-skip protocols/ftp
```

## 总结

Zeek性能优化是一个系统性工程，需要从系统内核、网络接口、Zeek配置和脚本等多个层面综合考虑。通过持续监控和定期调优，可以在高吞吐量网络环境中实现稳定的性能表现。关键是根据实际流量特征和硬件能力进行针对性优化。
