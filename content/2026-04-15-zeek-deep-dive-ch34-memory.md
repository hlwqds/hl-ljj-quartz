---
title: "Zeek 深度探索 (三十四)：内存调优"
date: 2026-04-15
tags:
  - zeek
  - series
  - memory
  - jemalloc
  - mimalloc
  - malloc
  - heap
  - performance
description: "深入解析 Zeek 内存管理——memory.log、malloc_trim、jemalloc/mimalloc 替代 allocator、堆内存分析、内存泄漏检测与排查"
---

> [!info] Zeek 2026 深度探索系列 0. [[2026-04-15-zeek-deep-dive-series-index|全栈学习路径总览]]
> ... 33. [[2026-04-08-zeek-deep-dive-ch33-performance-tuning|第三十三章：性能调优与高级配置]] 34. **第三十四章：内存调优** 35. [[2026-04-15-zeek-deep-dive-ch35-scripts|第三十五章：脚本优化]] 36. [[2026-04-15-zeek-deep-dive-ch36-hardware|第三十六章：硬件加速]] 37. [[2026-04-15-zeek-deep-dive-ch37-tuning|第三十七章：Tuning 清单]]

---

## 1. Zeek 内存架构概述

Zeek 的内存管理涉及多个层面：从底层系统 allocator 到 Zeek 内部的连接状态管理、事件队列、协议解析器缓存。理解这些层次是进行有效内存调优的基础。

```
┌─────────────────────────────────────────────────────────────┐
│                    Zeek 内存管理层次                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Application Layer                       │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │    │
│  │  │  Connection │  │   Event     │  │   Script    │ │    │
│  │  │   State     │  │   Queue     │  │   Objects   │ │    │
│  │  └─────────────┘  └─────────────┘  └─────────────┘ │    │
│  └─────────────────────────────────────────────────────┘    │
│                           ↓                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Allocator Layer                         │    │
│  │  ┌─────────────────────────────────────────────┐   │    │
│  │  │     jemalloc / mimalloc / glibc malloc       │   │    │
│  │  └─────────────────────────────────────────────┘   │    │
│  └─────────────────────────────────────────────────────┘    │
│                           ↓                                   │
│  ┌─────────────────────────────────────────────────────┐    │
│  │              Kernel Layer                           │    │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐ │    │
│  │  │    brk()    │  │    mmap()   │  │    Page     │ │    │
│  │  │   (heap)    │  │  (anonymous │  │    Cache    │ │    │
│  │  └─────────────┘  │   memory)    │  └─────────────┘ │    │
│  │                   └─────────────┘                    │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Zeek 主要内存消耗源

| 组件               | 内存消耗 | 配置参数                                   |
| :----------------- | :------- | :----------------------------------------- |
| **连接状态表**     | 高       | `max_connection_state`                     |
| **DNS 缓存**       | 中       | `dns_cache_size`, `dns_ttl_uid_cache_size` |
| **事件队列**       | 中       | `event_queue_size`                         |
| **协议解析器**     | 中       | `analyzer_max_depth`                       |
| **文件提取缓存**   | 高       | `extract_file_size_limit`                  |
| **正则表达式缓存** | 高       | `pattern_cache_size`                       |
| **日志缓冲区**     | 中       | `log_buffer_size`                          |

---

## 2. memory.log 详解

Zeek 的 `memory.log` 是监控内存使用情况的重要工具。当启用内存统计时，Zeek 会定期输出各组件的内存使用情况。

### 2.1 启用 memory.log

```zeek
# local.zeek
@load tuning/memory

# 配置内存统计间隔
redef memory_update_interval = 60 secs;
```

```bash
# 或通过命令行启用
zeek -m memory /path/to/scripts
```

### 2.2 memory.log 字段解析

```
#fields ts      mem     pkts_proc  events_proc  timers  conc_c   conc_a
#types time    count   count      count        count   count    count
1637845562.123456  2048576   1234567    234567      1234    5678    90
```

| 字段          | 类型  | 说明                   |
| :------------ | :---- | :--------------------- |
| `ts`          | time  | 时间戳                 |
| `mem`         | count | RSS 内存使用量（字节） |
| `pkts_proc`   | count | 已处理包数             |
| `events_proc` | count | 已处理事件数           |
| `timers`      | count | 活跃定时器数           |
| `conc_c`      | count | 活跃连接数             |
| `conc_a`      | count | 活跃分析器数           |

### 2.3 内存异常检测

```zeek
# memory-monitor.zeek

module MemoryMonitor;

export {
    global memory_threshold: count = 8GB;  # 8GB 阈值
    global growth_rate_threshold: double = 1.5;  # 1.5x 增长率
}

global last_mem: count = 0;
global last_time: time = 0.0;

event memory_update(s: memory_stats) {
    local current_time = network_time();

    if ( last_time > 0.0 ) {
        local time_delta = current_time - last_time;
        local mem_delta = s$mem - last_mem;
        local growth_rate = (double(mem_delta) / double(last_mem)) / time_delta;

        # 检测内存增长异常
        if ( growth_rate > growth_rate_threshold ) {
            Reporter::info(fmt("Memory growth rate anomaly: %.2f bytes/sec", growth_rate));
        }

        # 检测内存使用超阈值
        if ( s$mem > memory_threshold ) {
            Reporter::warning(fmt("Memory usage exceeded threshold: %.2f GB",
                double(s$mem) / 1GB));
        }
    }

    last_mem = s$mem;
    last_time = current_time;
}
```

---

## 3. 底层 Allocator 配置

### 3.1 glibc malloc (默认)

Zeek 默认使用 glibc 的 ptmalloc2，其调优主要通过环境变量：

```bash
# MALLOC_MMAP_THRESHOLD_: 超过此值的请求使用 mmap 而非 brk
export MALLOC_MMAP_THRESHOLD_=131072  # 128KB

# MALLOC_TRIM_THRESHOLD_: 调用 malloc_trim 的阈值
export MALLOC_TRIM_THRESHOLD_=1048576  # 1MB

# MALLOC_TOP_PAD_: 扩展堆时的 padding
export MALLOC_TOP_PAD_=1048576

# MALLOC_ARENA_TEST: arenas 数量（多核）
export MALLOC_ARENA_TEST=64
```

### 3.2 jemalloc 安装与配置

jemalloc 是 Facebook 开发的内存分配器，在多核环境下性能优于 glibc malloc：

```bash
# 安装 jemalloc
# Ubuntu/Debian
sudo apt-get install libjemalloc-dev

# RHEL/CentOS
sudo yum install jemalloc-devel

# 源码编译
wget https://github.com/jemalloc/jemalloc/releases/download/5.3.0/jemalloc-5.3.0.tar.bz2
tar xjf jemalloc-5.3.0.tar.bz2
cd jemalloc-5.3.0
./configure --prefix=/usr/local
make -j$(nproc)
sudo make install
```

```bash
# 使用 jemalloc 启动 Zeek
LD_PRELOAD=/usr/local/lib/libjemalloc.so.2 zeek /path/to/scripts

# 验证 allocator
lsof -p $(pidof zeek) | grep jemalloc
```

### 3.3 mimalloc 安装与配置

mimalloc 是 Microsoft 开发的轻量级高性能 allocator：

```bash
# 安装 mimalloc
# Ubuntu/Debian
sudo apt-get install libmimalloc-dev

# 源码编译
wget https://github.com/microsoft/mimalloc/releases/download/v2.0.9/mimalloc-2.0.9.tar.gz
tar xzf mimalloc-2.0.9.tar.gz
cd mimalloc-2.0.9
cmake -DCMAKE_INSTALL_PREFIX=/usr/local .
make -j$(nproc)
sudo make install
```

```bash
# 使用 mimalloc 启动 Zeek
LD_PRELOAD=/usr/local/lib/libmimalloc.so zeek /path/to/scripts
```

### 3.4 Allocator 对比

| 特性           | glibc malloc | jemalloc | mimalloc |
| :------------- | :----------- | :------- | :------- |
| **多核扩展性** | 中           | 高       | 高       |
| **内存碎片**   | 中           | 低       | 很低     |
| **锁竞争**     | 高           | 低       | 很低     |
| **吞吐量**     | 中           | 高       | 很高     |
| **内存占用**   | 低           | 中       | 中       |
| **安全特性**   | 无           | 红黑区   | 安全分区 |

```bash
# 使用 perf 比较 allocator 性能
perf stat -e 'cache-misses,cache-references,context-switches' \
    LD_PRELOAD=/usr/local/lib/libmimalloc.so zeek /path/to/scripts
```

---

## 4. malloc_trim 机制

`malloc_trim` 是 glibc 提供的功能，用于将未使用的堆内存归还给操作系统。这对内存资源受限的环境非常重要。

### 4.1 工作原理

```
┌─────────────────────────────────────────────────────────────┐
│                    malloc_trim 原理                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  Before malloc_trim:                                        │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [ Used ] [ Used ] [ Free ] [ Used ] [ Free ]        │   │
│  │              ↑              ↑                         │   │
│  │         top pad         released                      │   │
│  └─────────────────────────────────────────────────────┘   │
│                           ↓                                  │
│                     malloc_trim()                            │
│                           ↓                                  │
│  After malloc_trim:                                          │
│  ┌─────────────────────────────────────────────────────┐   │
│  │ [ Used ] [ Used ] [ Used ]                           │   │
│  └─────────────────────────────────────────────────────┘   │
│                    (freed memory returned to OS)             │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Zeek 中自动调用 malloc_trim

```zeek
# zeek/scripts/base/tuning/malloc-trim.zeek

module MallocTrim;

export {
    # malloc_trim 调用间隔（默认 5 分钟）
    redef trim_interval = 5mins;

    # 最小释放阈值（字节）
    # 只有当可释放内存超过此值时才调用 trim
    redef min_trim_size = 1MB;
}

event zeek_init() {
    schedule trim_interval { malloc_trim_timer() };
}

event malloc_trim_timer() {
    # 调用 C++ 内置的 malloc_trim
    builtin_malloc_trim(min_trim_size);

    # 调度下一次调用
    schedule trim_interval { malloc_trim_timer() };
}
```

### 4.3 手动调用 malloc_trim

```bash
# 通过 gdb 手动调用 malloc_trim
gdb -p $(pidof zeek) -ex "call malloc_trim(0)" -batch
```

```bash
# 编写脚本自动化
#!/bin/bash
# trim-zeek.sh

ZEEK_PID=$(pidof zeek)
if [ -n "$ZEEK_PID" ]; then
    gdb -p $ZEEK_PID -ex "call malloc_trim(0)" -batch 2>/dev/null
    echo "$(date): malloc_trim called" >> /var/log/zeek-trim.log
fi
```

```bash
# 添加到 crontab 每 5 分钟执行
*/5 * * * * /usr/local/bin/trim-zeek.sh
```

### 4.4 何时使用 malloc_trim

| 场景                  | 建议                 |
| :-------------------- | :------------------- |
| 内存受限环境（云 VM） | 启用，间隔 1-5 分钟  |
| 高吞吐量服务器        | 禁用或延长间隔       |
| 内存泄漏排查          | 禁用（保持内存快照） |
| 容器化部署            | 启用，避免 OOM       |

---

## 5. 内存泄漏检测与排查

### 5.1 使用 gperftools 检测内存泄漏

```bash
# 安装 gperftools
sudo apt-get install google-perftools libgoogle-perftools-dev

# 启用 heap profiling
env HEAPPROFILE=/var/log/zeek/heap zeek /path/to/scripts

# 生成泄漏报告
google-pprof --text zeek /var/log/zeek/heap.0014.heap | less
```

```bash
# 使用 gperftools 的 heap-checker
env HEAPCHECK=normal zeek /path/to/scripts

# 输出示例
# Leaked 12345678 bytes in 999 objects
# Process total heap memory: 1234567890 bytes
# Leak check build: Normal
```

### 5.2 Valgrind 检测内存泄漏

```bash
# 安装 valgrind
sudo apt-get install valgrind

# 运行 Zeek（性能会大幅下降，仅用于测试）
valgrind --leak-check=full --log-file=/var/log/zeek-valgrind.log \
    /usr/local/zeek/bin/zeek /path/to/scripts
```

```bash
# 查找泄漏点
grep -A 10 "definitely lost" /var/log/zeek-valgrind.log
```

### 5.3 Zeek 内部泄漏检测

```zeek
# zeek/scripts/base/tuning/heap-debug.zeek

@load base/utils/heap

# 启用堆内存跟踪
redef heap_tracking = T;

# 设置告警阈值
redef heap_warning_threshold = 2GB;
redef heap_critical_threshold = 4GB;

# 定期输出堆信息
event heap_stats_update(h: heap_info) {
    print fmt("Heap: %.2f MB allocated, %.2f MB in use",
        double(h$total) / 1MB, double(h$in_use) / 1MB);
    print fmt("Objects: %d, Allocations: %d, Frees: %d",
        h$objects, h$allocations, h$frees);
}
```

### 5.4 常见内存泄漏模式

```zeek
# 差：全局变量累积
global connection_store: table[string] of connection_state;

event new_connection(c: connection) {
    # 永远不清理！
    connection_store[c$id] = c$state;
}

# 好：使用 scoped 变量
event new_connection(c: connection) {
    local state = c$state;  # 函数结束自动释放
    # 处理完成后自然释放
}

# 好：定期清理
event new_connection(c: connection) {
    connection_store[c$id] = c$state;

    # 定期清理过期条目
    if ( |connection_store| > 100000 ) {
        for ( id in connection_store ) {
            if ( connection_store[id]$last_activity + 1hr < network_time() ) {
                delete connection_store[id];
            }
        }
    }
}
```

---

## 6. 连接状态内存优化

### 6.1 连接状态表大小限制

```zeek
# local.zeek

# 最大连接数（内存相关）
redef max_connection_state = 1000000;  # 100 万连接

# 连接状态超时
redef connection_state_timeout = 5mins;

# 半开连接超时（未完成三次握手）
redef pending_connection_timeout = 30secs;
```

### 6.2 DNS 缓存优化

```zeek
# DNS 缓存大小
redef dns_cache_size = 100000;        # 10 万条缓存
redef dns_ttl_uid_cache_size = 100000;

# DNS 缓存超时
redef dns_max_ttl = 1day;
redef dns_min_ttl = 1min;

# 关闭 DNS 缓存（节省内存但增加延迟）
# redef dns_cache_size = 0;
```

### 6.3 文件提取内存限制

```zeek
# 文件提取总内存限制
redef file_extract_total_size_limit = 100MB;

# 单个文件大小限制
redef extract_file_size_limit = 10MB;

# 提取文件数量限制
redef max_file_extract_size = 50;
```

---

## 7. 内存调优配置清单

### 7.1 sysctl.conf 配置

```bash
# /etc/sysctl.d/99-zeek-memory.conf

# 虚拟内存调优
vm.swappiness = 10
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
vm.vfs_cache_pressure = 50

# 内存映射限制
vm.max_map_count = 655360

# TCP 内存
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
```

### 7.2 limits.conf 配置

```bash
# /etc/security/limits.d/zeek.conf

zeek soft memlock unlimited
zeek hard memlock unlimited
zeek soft as unlimited
zeek hard as unlimited
```

### 7.3 Zeek 内存配置

```zeek
# memory-tuning.zeek

# 连接表
redef max_connection_state = 1000000;
redef connection_state_timeout = 5mins;

# DNS 缓存
redef dns_cache_size = 100000;

# 文件提取
redef file_extract_total_size_limit = 500MB;
redef extract_file_size_limit = 50MB;

# 事件队列
redef event_queue_size = 10000;

# 日志缓冲
redef log_buffer_size = 8MB;
redef log_write_buffer_size = 8192;
```

---

## 8. 监控与告警

### 8.1 Prometheus 内存指标

```zeek
# prometheus-memory.zeek

@load base/misc/perfstats

module MemoryMetrics;

export {
    global metrics_port: port = 9092/tcp;
}

event memory_update(s: memory_stats) {
    local mem_mb = double(s$mem) / 1MB;

    # 输出 Prometheus 格式
    print fmt("# HELP zeek_memory_rss_bytes Resident set size");
    print fmt("# TYPE zeek_memory_rss_bytes gauge");
    print fmt("zeek_memory_rss_bytes{node=\"%s\"} %.2f",
        Cluster::node, mem_mb * 1024 * 1024);
}
```

### 8.2 告警脚本

```bash
#!/bin/bash
# memory-alert.sh

THRESHOLD_GB=8
LOG_FILE=/var/log/zeek/memory.log

# 读取最新内存使用
MEM_GB=$(tail -1 $LOG_FILE | awk '{print int($2/1024/1024)}')

if [ $MEM_GB -gt $THRESHOLD_GB ]; then
    echo "WARNING: Zeek memory usage ${MEM_GB}GB exceeds threshold ${THRESHOLD_GB}GB"
    # 发送告警（根据实际情况选择告警方式）
    # curl -X POST "https://alert.example.com/webhook" -d "Zeek memory alert"
fi
```

```bash
# crontab 中添加监控
*/5 * * * * /usr/local/bin/memory-alert.sh
```
