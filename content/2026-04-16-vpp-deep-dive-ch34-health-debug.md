---
title: "VPP 深入探讨 ch34：健康检查与故障排查"
date: 2026-04-16 10:44:00
tags: [vpp, health-check, debugging, troubleshooting, diagnostics, crash, coredump]
description: "深入解析 VPP 健康检查与故障排查：健康检查机制、crash 分析、coredump 配置、常见问题诊断与性能问题排查"
---

# VPP 深入探讨 ch34：健康检查与故障排查

> [!abstract] 核心要点
> 生产环境需要完善的健康检查和故障排查机制。本章详解 VPP 健康检查机制、crash 分析、coredump 配置、常见问题诊断与性能问题排查。

## 1. 健康检查机制

### 1.1 健康检查架构

```
┌─────────────────────────────────────────────────────────────┐
│                  VPP 健康检查架构                            │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                    VPP Process                       │   │
│   │                                                      │   │
│   │   ┌───────────────┐  ┌───────────────┐             │   │
│   │   │  Self-Check   │  │  Plugin       │             │   │
│   │   │  (Internal)   │  │  Health       │             │   │
│   │   └───────┬───────┘  └───────┬───────┘             │   │
│   │           │                  │                      │   │
│   │           └────────┬─────────┘                      │   │
│   │                    │                                  │   │
│   │           ┌────────▼────────┐                       │   │
│   │           │  Health Server  │                        │   │
│   │           │  (UNIX Socket)   │                        │   │
│   │           └────────┬────────┘                        │   │
│   └────────────────────┼─────────────────────────────────┘   │
│                        │                                      │
│   ┌────────────────────┼─────────────────────────────────┐   │
│   │     External       │    External                     │   │
│   │   ┌────────────────▼────────────────┐                 │   │
│   │   │     Health Check Client          │                │   │
│   │   │   (Keepalived / Kubernetes / Prometheus)          │   │
│   │   └────────────────────────────────────┘                │   │
│   │                    │                                      │
│   │   ┌────────────────┼────────────────┐                 │   │
│   │   │                │                │                  │   │
│   │ ┌─▼───┐        ┌────▼───┐      ┌─────▼─────┐          │   │
│   │ │TCP   │        │HTTP   │      │gRPC        │          │   │
│   │ │Check │        │Check  │      │Check       │          │   │
│   │ └──────│        │───────│      │────────────│          │   │
│   └────────┼────────┼───────┼──────┼────────────┼──────────┘   │
│            │        │       │      │            │                │
│            └────────┴───────┴──────┴────────────┘                │
│                    Health Check Types                            │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 内置健康检查

```bash
# 查看健康检查状态
vppctl show health

# 示例输出：
# Health Check Status:
#   Overall: healthy
#   Uptime: 15 days 5 hours 23 minutes
#   Last check: 10:30:00
#
# Component checks:
#   Memory:      [OK]  used: 8GB/32GB (25%)
#   Buffers:     [OK]  available: 229376/262144
#   Interfaces:  [OK]  4/4 up
#   Workers:     [OK]  8/8 active
#  Plugins:      [OK]  all enabled

# 详细健康检查
vppctl show health detail

# 示例输出：
# Memory Details:
#   Main heap: 1GB used / 4GB total
#   Buffer pool: 512MB used / 1GB total
#   Code/Data: 128MB
#
# Interface Details:
#   TenGigabitEthernet0/0/0: up (link up, 10G FDX)
#   TenGigabitEthernet0/0/1: up (link up, 10G FDX)
#   TenGigabitEthernet0/0/2: up (link up, 10G FDX)
#   TenGigabitEthernet0/0/3: up (link up, 10G FDX)
#
# Worker Details:
#   Worker 0: active (CPU 1, 85% util)
#   Worker 1: active (CPU 2, 82% util)
#   ...
```

### 1.3 健康检查 API

```bash
# 通过 UNIX socket 查询健康状态
echo "status" | nc -U /run/vpp/health.sock

# 示例响应：
# HTTP/1.1 200 OK
# Content-Type: application/json
#
# {
#   "status": "healthy",
#   "timestamp": "2026-04-16T10:30:00Z",
#   "checks": {
#     "memory": "ok",
#     "buffers": "ok",
#     "interfaces": "ok",
#     "workers": "ok"
#   }
# }

# gRPC 健康检查接口
grpcurl -plaintext localhost:5001 list
# grpc.health.v1.Health
# vpp.ChassisControl

# 检查 VPP 健康状态
grpcurl -plaintext -d '{"service": ""}' localhost:5001/grpc.health.v1.Health/Check
```

### 1.4 Kubernetes 健康检查

```yaml
# Kubernetes Pod spec 中的健康检查
apiVersion: v1
kind: Pod
metadata:
  name: vpp-pod
spec:
  containers:
    - name: vpp
      image: vpp:latest
      ports:
        - containerPort: 5001 # gRPC
          name: grpc
        - containerPort: 9932 # Telemetry
          name: telemetry

      # 存活探针 (Liveness Probe)
      livenessProbe:
        tcpSocket:
          port: 5001
        initialDelaySeconds: 30
        periodSeconds: 10
        timeoutSeconds: 5
        failureThreshold: 3

      # 就绪探针 (Readiness Probe)
      readinessProbe:
        httpGet:
          path: /metrics
          port: 9932
        initialDelaySeconds: 10
        periodSeconds: 5
        timeoutSeconds: 3
        failureThreshold: 3

      # 启动探针 (Startup Probe)
      startupProbe:
        exec:
          command:
            - vppctl
            - show
            - health
        initialDelaySeconds: 10
        periodSeconds: 5
        timeoutSeconds: 3
        failureThreshold: 30
```

### 1.5 Keepalived VRRP 健康检查

```bash
# keepalived.conf 中的 VPP 健康检查
vrrp_instance VPP_HA {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1

    # 健康检查脚本
    track_script {
        check_vpp
    }

    # VIP
    virtual_ipaddress {
        10.0.0.100/24 dev eth0
    }
}

# 健康检查脚本
cat /etc/keepalived/check_vpp.sh
#!/bin/bash
# check_vpp.sh - VPP 健康检查脚本

# 检查 VPP 进程
if ! pgrep -x vpp > /dev/null; then
    echo "VPP process not running"
    exit 1
fi

# 检查健康端点
response=$(echo "status" | nc -U /run/vpp/health.sock 2>/dev/null)
if ! echo "$response" | grep -q "healthy"; then
    echo "VPP health check failed"
    exit 1
fi

# 检查接口状态
up_count=$(vppctl show interface | grep -c "up" || true)
if [ "$up_count" -lt 2 ]; then
    echo "Not enough interfaces up"
    exit 1
fi

exit 0

# 设置执行权限
chmod +x /etc/keepalived/check_vpp.sh
```

## 2. Crash 分析

### 2.1 Crash 类型

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Crash 类型                            │
│                                                              │
│   1. Assert Crash                                            │
│      - VLIBAssert() 失败                                     │
│      - 内存损坏/非法指针访问                                  │
│                                                              │
│   2. Hang/Deadlock                                           │
│      - 线程死锁                                              │
│      - 调度饥饿                                              │
│      - 永久阻塞在某个操作                                    │
│                                                              │
│   3. OOM (Out of Memory)                                      │
│      - Buffer 耗尽                                          │
│      - 内存分配失败                                          │
│      - 内存泄漏                                              │
│                                                              │
│   4. Signal Crash                                            │
│      - SIGSEGV: 段错误                                      │
│      - SIGABRT: assert 失败                                  │
│      - SIGFPE: 浮点异常                                      │
│      - SIGBUS: 总线错误                                      │
│                                                              │
│   5. Watchdog Timeout                                        │
│      - worker 线程超过阈值未响应                              │
│      - 主线程阻塞                                           │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Coredump 配置

```bash
# 1. 系统级 coredump 配置

# 查看当前 coredump 配置
cat /proc/sys/kernel/core_pattern

# 示例输出：
# /var/crash/core.%e.%p.%t

# 临时设置（重启失效）
mkdir -p /var/crash
chmod 777 /var/crash
echo "/var/crash/core.%e.%p.%t" > /proc/sys/kernel/core_pattern

# 永久设置 (/etc/sysctl.conf)
echo "kernel.core_pattern = /var/crash/core.%e.%p.%t" >> /etc/sysctl.conf
echo "kernel.max_coredump = 10737418240" >> /etc/sysctl.conf  # 10GB
sysctl -p

# 2. coredump 大小限制
ulimit -c unlimited

# 永久设置 (/etc/security/limits.conf)
*    soft    core    unlimited
*    hard    core    unlimited

# 3. VPP coredump 配置
# startup.conf
unix {
    # 启用 full coredump（包含堆）
    full-coredump

    # 或设置 coredump 目录
    # coredump-config /etc/vpp/coredump
}
```

### 2.3 Crash 分析工具

```bash
# 使用 VPP 内置 crash 分析
vppctl show crash

# 示例输出：
# Crash info:
#   Time: 2026-04-16 10:30:00
#   Signal: SIGSEGV (11)
#   Reason: segmentation fault
#   Thread: vpp_worker_0 (PID 1234)
#
# Stack trace:
#   #0  0x00007f9a4b000 in ip4_rewrite_inline
#   #1  0x00007f9a4c000 in ip4_rewrite_node
#   #2  0x00007f9a4d000 in vlib_dispatch_node
#   ...

# 使用 addr2line 解析地址
addr2line -e /usr/lib/vpp/bin/vpp-main-debug \
    0x00007f9a4b000 \
    0x00007f9a4c000

# 示例输出：
# /usr/src/vpp/build-root/install-vpp-native/vpp/src/vnet/ip/ip4_rewrite.c:123
# /usr/src/vpp/build-root/install-vpp-native/vpp/src/vnet/ip/ip4_rewrite.c:145

# 使用 gdb 分析
gdb /usr/lib/vpp/bin/vpp /var/crash/core.vpp.1234.1713258000

(gdb) bt        # backtrace
(gdb) info threads
(gdb) thread apply all bt
(gdb) frame 2   # 切换到 frame 2
(gdb) p buffer  # 打印变量
```

### 2.4 Crash 脚本自动化

```bash
#!/bin/bash
# vpp_crash_analyzer.sh - VPP crash 自动分析

CRASH_DIR="/var/crash"
VPP_BINARY="/usr/lib/vpp/bin/vpp"
OUTPUT_DIR="/var/log/vpp/crash_analysis"

mkdir -p $OUTPUT_DIR

# 处理所有 crash 文件
for core in $CRASH_DIR/core.*; do
    if [ ! -f "$core" ]; then
        continue
    fi

    echo "Analyzing: $core"

    # 提取 crash 信息
    basename=$(basename $core)
    timestamp=$(echo $basename | cut -d. -f4)
    pid=$(echo $basename | cut -d. -f3)
    executable=$(echo $basename | cut -d. -f2)

    report="$OUTPUT_DIR/crash_${timestamp}.txt"

    {
        echo "VPP Crash Analysis Report"
        echo "========================"
        echo "Timestamp: $(date -d @$timestamp)"
        echo "PID: $pid"
        echo "Executable: $executable"
        echo "Core file: $core"
        echo ""

        # 获取 crash 时间前后的日志
        echo "Log entries around crash time:"
        grep -E "^\[$(date -d @$timestamp '+%Y-%m-%d %H:%M' | sed 's/:/\n/g' | head -1)\]" /var/log/vpp.log 2>/dev/null | head -20
        echo ""

        # 栈追踪
        echo "Stack trace:"
        gdb -batch -ex "bt" -ex "thread apply all bt" $VPP_BINARY $core 2>/dev/null | head -100

    } > "$report"

    echo "Report saved to: $report"
    echo ""

    # 移动 core 文件到存档目录
    archive_dir="$CRASH_DIR/archive"
    mkdir -p $archive_dir
    mv $core $archive_dir/
done

# 清理旧报告（保留 30 天）
find $OUTPUT_DIR -name "crash_*.txt" -mtime +30 -delete
```

## 3. 故障排查指南

### 3.1 常见问题诊断流程

```
┌─────────────────────────────────────────────────────────────┐
│                  VPP 故障排查流程                            │
│                                                              │
│   Step 1: 确认问题范围                                       │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  ? VPP 完全无响应                                     │   │
│   │  ? 部分接口不通                                       │   │
│   │  ? 性能下降                                          │   │
│   │  ? 丢包增加                                          │   │
│   └─────────────────────────────────────────────────────┘   │
│                          ↓                                   │
│   Step 2: 检查基础状态                                       │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  vppctl show version      # 版本确认                  │   │
│   │  vppctl show interface    # 接口状态                  │   │
│   │  vppctl show threads      # 线程状态                  │   │
│   │  vppctl show errors       # 错误统计                  │   │
│   │  vppctl show memory       # 内存状态                  │   │
│   └─────────────────────────────────────────────────────┘   │
│                          ↓                                   │
│   Step 3: 深入分析                                          │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  vppctl show node          # Node 统计               │   │
│   │  vppctl show graph         # Graph 结构              │   │
│   │  vppctl show trace         # 包追踪                  │   │
│   │  perf top -p $(pgrep vpp)  # CPU profiling           │   │
│   └─────────────────────────────────────────────────────┘   │
│                          ↓                                   │
│   Step 4: 采取行动                                          │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  恢复：重启接口/重启 VPP/回滚配置                     │   │
│   │  修复：调整配置/升级/修复代码                         │   │
│   │  预防：添加监控/调整阈值                              │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 接口相关问题

```bash
# 问题：接口 down
# 排查步骤：

# 1. 检查 VPP 接口状态
vppctl show interface TenGigabitEthernet0/0/0

# 2. 检查物理链路状态
ip link show eth0
ethtool eth0

# 3. 检查 NIC 统计
ethtool -S eth0

# 4. 查看相关错误
vppctl show errors | grep -i "TenGigabitEthernet0/0/0"

# 常见原因与解决：
# - 链路协商失败：检查双工/速率配置
# - NIC 驱动问题：更新驱动或固件
# - 硬件故障：更换网口/NIC

# 问题：丢包严重
# 排查步骤：

# 1. 查看丢包统计
vppctl show interface TenGigabitEthernet0/0/0 drops

# 2. 按 node 分析丢包
vppctl show node | grep -i drop

# 3. 检查 buffer 状态
vppctl show buffer

# 4. 检查内存
vppctl show memory

# 常见原因与解决：
# - Buffer 耗尽：增加 buffer pool 大小
# - 软件队列满：调整 TX 队列大小
# - ACL 匹配：检查 ACL 规则
```

### 3.3 性能下降问题

```bash
# 问题：吞吐下降
# 排查步骤：

# 1. 对比基准性能
echo "Current performance:"
vppctl show interface stats

# 2. 检查 CPU 使用
vppctl show threads

# 3. 检查是否有热点
vppctl show node sort-by-cycles | head -20

# 4. 检查 interrupt coalescing
ethtool -c eth0

# 5. 检查 RSS 配置
vppctl show rss

# 常见原因与解决：
# - 单核瓶颈：增加 worker 数量
# - RSS 不均衡：重新配置 indirection table
# - 中断风暴：调整 coalescing 参数

# 问题：延迟增加
# 排查步骤：

# 1. 检查调度延迟
vppctl show dispatch stats

# 2. 检查队列深度
vppctl show interface TenGigabitEthernet0/0/0 queue-stats

# 3. 使用 packet pacing 测试
vppctl set interface tx pacing TenGigabitEthernet0/0/0 1000

# 4. 检查 CPU 调度
cat /proc/interrupts | grep eth0
```

### 3.4 内存问题

```bash
# 问题：内存使用持续增长
# 排查步骤：

# 1. 监控内存使用趋势
while true; do
    vppctl show memory | grep "used"
    sleep 60
done >> /var/log/vpp_memory.log

# 2. 检查是否有内存泄漏
vppctl show memory verbose

# 3. 检查 buffer 泄漏
vppctl show buffer verbose | grep "allocated"

# 4. 使用 valgrind 检测（测试环境）
valgrind --leak-check=full vpp

# 常见原因：
# - FIB 表过大：清理无效路由
# - 邻接表泄漏：检查 ARP/NDP 条目
# - Buffer 泄漏：检查未释放的 buffer

# 问题：OOM
# 排查步骤：

# 1. 查看 OOM 日志
dmesg | grep -i "out of memory"
journalctl | grep -i "oom"

# 2. 检查 VPP 内存限制
vppctl show memory

# 3. 调整内存限制
# startup.conf
unix {
    hugeheap {
        # 设置 hugepage 数量
        # default heap size
    }
}
```

## 4. 调试技巧

### 4.1 包追踪调试

```bash
# 启用包追踪
vppctl trace add dpdk-input 100

# 在特定接口启用追踪
vppctl trace add TenGigabitEthernet0/0/0-input 100

# 追踪特定协议
vppctl trace add ip4-lookup 100

# 追踪 NAT
vppctl trace add nat44-out 50

# 查看追踪结果
vppctl show trace

# 保存追踪到文件
vppctl exec "show trace" > /tmp/trace.txt

# 清除追踪
vppctl clear trace

# 条件追踪（仅追踪特定包）
vppctl trace filter src 10.0.0.1
vppctl trace filter dst 192.168.1.0/24
vppctl trace filter protocol tcp
vppctl trace filter port 80

# 清除过滤
vppctl trace filter clear
```

### 4.2 运行时调试

```bash
# 启用 debug 模式
vppctl set debug on

# 查看所有调试选项
vppctl show debug

# 调试特定模块
vppctl debug ip4 all
vppctl debug nat44 all
vppctl debug acl all

# 关闭调试
vppctl debug all off

# 查看实时包流（类似 tcpdump）
vppctl exec "packet-manager trace start"
vppctl exec "packet-manager trace stop"
vppctl exec "packet-manager trace show"

# 接口 RX/TX 调试
vppctl set interface rx on TenGigabitEthernet0/0/0
vppctl set interface tx on TenGigabitEthernet0/0/0
```

### 4.3 RPC 调试

```bash
# 查看 API 调用统计
vppctl show api

# 示例输出：
# API Statistics:
#   Total calls: 1234567
#   Failed calls: 12
#   Active clients: 3
#
#   Calls by type:
#     sw_interface_dump: 123456
#     ip_addr_add: 12345
#     l2_patch_add_del: 1234

# 查看 API 客户端
vppctl show api clients

# 示例输出：
# API Client: local
#   PID: 1234
#   Name: vppctl
#   Calls: 56789
#
# API Client: gRPC (192.168.1.100:5001)
#   PID: 5678
#   Name: vpp-manager
#   Calls: 123456

# API 追踪
vppctl exec "api trace on"
vppctl exec "api trace show"
vppctl exec "api trace clear"
```

### 4.4 网络命名空间调试

```bash
# 进入 VPP 网络命名空间
ip netns exec vppns bash

# 在命名空间内运行 VPP 命令
ip netns exec vppns vppctl show interface

# 查看命名空间内的路由
ip netns exec vppns ip route

# 查看命名空间内的 ARP
ip netns exec vppns ip neigh

# 抓包（命名空间内）
ip netns exec vppns tcpdump -i vpp0 -w /tmp/vpp_capture.pcap
```

## 5. 自动化故障恢复

### 5.1 自动恢复脚本

```bash
#!/bin/bash
# vpp_auto_recovery.sh - VPP 自动故障恢复

VPP_PID=$(pgrep -x vpp)
LOG_FILE="/var/log/vpp_recovery.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> $LOG_FILE
}

# 检查 VPP 是否存活
check_vpp() {
    if pgrep -x vpp > /dev/null; then
        return 0
    else
        return 1
    fi
}

# 检查接口健康
check_interfaces() {
    up_count=$(vppctl show interface | grep -c "up" || echo 0)
    if [ "$up_count" -lt 2 ]; then
        log "WARNING: Only $up_count interfaces up"
        return 1
    fi
    return 0
}

# 检查 worker 健康
check_workers() {
    active=$(vppctl show threads | grep -c "active" || echo 0)
    expected=$(nproc)
    if [ "$active" -lt "$expected" ]; then
        log "WARNING: Only $active/$expected workers active"
        return 1
    fi
    return 0
}

# 恢复操作
recover_vpp() {
    log "Attempting VPP recovery..."

    # 方法1: 重启接口
    for iface in $(vppctl show interface | awk '/^[A-Z]/{print $1}'); do
        vppctl set interface state $iface down
        sleep 1
        vppctl set interface state $iface up
        log "Restarted interface: $iface"
    done

    # 方法2: 等待自动恢复
    sleep 5

    # 方法3: 进程重启（如果上述失败）
    if ! check_vpp; then
        log "VPP process dead, restarting..."
        systemctl restart vpp
    fi
}

# 主循环
while true; do
    if ! check_vpp; then
        log "VPP not running, attempting restart"
        systemctl restart vpp
        sleep 30
        continue
    fi

    if ! check_interfaces; then
        log "Interface health check failed"
        recover_vpp
    fi

    if ! check_workers; then
        log "Worker health check failed"
        # 重启单个 worker（如果支持）
        vppctl restart workers
    fi

    sleep 60
done
```

### 5.2 故障转移脚本

```bash
#!/bin/bash
# vpp_failover.sh - VPP 故障转移脚本

PRIMARY_VPP="192.168.1.100"
BACKUP_VPP="192.168.1.101"
VIP="192.168.1.200"
CHECK_INTERVAL=5

log() {
    logger -t vpp_failover "$1"
}

# 检查主 VPP 健康
check_primary() {
    # 通过 gRPC 检查
    response=$(grpc_health_probe -addr=$PRIMARY_VPP:5001 2>/dev/null)
    if [ "$?" -eq 0 ]; then
        return 0
    fi

    # 通过 vppctl 检查
    if ssh $PRIMARY_VPP "vppctl show version" > /dev/null 2>&1; then
        return 0
    fi

    return 1
}

# 故障转移
do_failover() {
    log "Primary VPP failed, initiating failover"

    # 1. 通知 Keepalived
    ip addr add $VIP/32 dev eth0 2>/dev/null

    # 2. 激活备份 VPP
    ssh $BACKUP_VPP "vppctl set interface state all up"

    # 3. 更新路由
    ip route replace default via $BACKUP_VPP

    log "Failover completed"
}

# 主循环
while true; do
    if ! check_primary; then
        do_failover
    fi
    sleep $CHECK_INTERVAL
done
```

### 5.3 状态快照与恢复

```bash
#!/bin/bash
# vpp_state_snapshot.sh - 状态快照与恢复

SNAPSHOT_DIR="/var/lib/vpp/snapshots"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

save_snapshot() {
    local name=$1

    mkdir -p $SNAPSHOT_DIR/$name

    # 保存接口配置
    vppctl exec "show interface" > $SNAPSHOT_DIR/$name/interfaces.txt

    # 保存 IP 地址
    vppctl exec "show interface address" > $SNAPSHOT_DIR/$name/ip_addresses.txt

    # 保存路由表
    vppctl exec "show ip fib" > $SNAPSHOT_DIR/$name/ip_routes.txt
    vppctl exec "show ip6 fib" > $SNAPSHOT_DIR/$name/ip6_routes.txt

    # 保存 ARP/NDP 表
    vppctl exec "show ip arp" > $SNAPSHOT_DIR/$name/arp.txt
    vppctl exec "show ip6 neighbor" > $SNAPSHOT_DIR/$name/ndp.txt

    # 保存 running config
    vppctl exec "show running" > $SNAPSHOT_DIR/$name/running_config.txt

    # 创建元数据
    cat > $SNAPSHOT_DIR/$name/metadata.txt << EOF
Snapshot Time: $(date)
VPP Version: $(vppctl show version | head -1)
Hostname: $(hostname)
EOF

    echo "Snapshot saved: $name"
}

restore_snapshot() {
    local name=$1

    if [ ! -d "$SNAPSHOT_DIR/$name" ]; then
        echo "Snapshot not found: $name"
        return 1
    fi

    echo "Restoring snapshot: $name"

    # 清除当前配置
    vppctl exec "reset" 2>/dev/null

    # 恢复配置（需要解析和应用）
    # 这部分需要根据实际配置格式实现

    echo "Snapshot restored: $name"
}

# 命令行接口
case "$1" in
    save)
        save_snapshot "${2:-manual_$TIMESTAMP}"
        ;;
    restore)
        restore_snapshot "$2"
        ;;
    list)
        ls -la $SNAPSHOT_DIR/
        ;;
    *)
        echo "Usage: $0 {save|restore|list} [name]"
        ;;
esac
```
