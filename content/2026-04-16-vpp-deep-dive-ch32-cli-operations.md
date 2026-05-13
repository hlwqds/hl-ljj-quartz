---
title: "VPP 深入探讨 ch32：CLI 与运维接口"
date: 2026-04-16 10:42:00
tags: [vpp, cli, vppctl, ops, management, unix-socket, stats, API]
description: "深入解析 VPP CLI 运维接口：vppctl 命令详解、UNIX socket API、stats 统计、show/debug 命令与批量操作"
---

# VPP 深入探讨 ch32：CLI 与运维接口

> [!abstract] 核心要点
> VPP 提供丰富的运维接口：CLI (vppctl)、UNIX socket API、stats API。本章详解常用运维命令、统计查看、调试技术与批量操作技巧。

## 1. VPP 运维架构

### 1.1 运维接口概述

```
┌─────────────────────────────────────────────────────────────┐
│                      VPP 运维接口架构                         │
│                                                              │
│   ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│   │   vppctl    │    │  UNIX Socket │    │  REST API   │     │
│   │  (CLI Tool) │    │   (Binary)   │    │  (JSON)     │     │
│   └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│          │                  │                  │             │
│          └──────────────────┼──────────────────┘             │
│                             │                               │
│                    ┌────────▼────────┐                      │
│                    │   VPP CLI Engine  │                     │
│                    │   (graph CLI)     │                     │
│                    └────────┬────────┘                      │
│                             │                               │
│          ┌──────────────────┼──────────────────┐            │
│          │                  │                  │            │
│   ┌──────▼──────┐    ┌──────▼──────┐    ┌──────▼──────┐     │
│   │  Stats API  │    │  CLI Parser │    │  Trace API  │     │
│   └─────────────┘    └─────────────┘    └─────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 运维接口类型

| 接口类型 | 默认地址 | 协议 | 适用场景 |
|----------|----------|------|----------|
| **vppctl (CLI)** | `/run/vpp/cli.sock` | Text/ASCII | 日常运维、调试 |
| **Stats API** | `/run/vpp/stats.sock` | Binary | 程序化监控 |
| **gRPC API** | `:5001` (可选) | Protocol Buffers | 远程管理、K8s |
| **REST API** | `:8080` (可选) | JSON/HTTP | Web 管理界面 |

### 1.3 连接方式

```bash
# 方式1: vppctl（默认路径）
vppctl

# 方式2: 指定 socket 路径
vppctl -s /run/vpp/cli.sock

# 方式3: 远程连接（通过 gRPC）
vppctl -r 192.168.1.100:5001

# 方式4: 一次性命令（无需交互）
vppctl "show version"
```

## 2. 核心 Show 命令

### 2.1 系统状态

```bash
# 查看 VPP 版本
vppctl show version

# 示例输出：
# vpp v24.02-release built by cl on 2024-02-15 10:30:00

# 查看系统信息
vppctl show system

# 示例输出：
# System run time: 15 days 5 hours 23 minutes 10 seconds
# Up time: 15 days 5 hours 23 minutes 10 seconds
# CPUs: 8 cores, 8 threads
# Memory: total: 32768 MB, used: 8192 MB, free: 24576 MB
```

### 2.2 接口管理

```bash
# 查看所有接口
vppctl show interface

# 示例输出：
#               Name                Idx    State  MTU   L3 addr
#           local0                     0     down   0     00:00:00:00:00:00
#       TenGigabitEthernet0/0/0        1     up    9000  00:11:22:33:44:55
#       TenGigabitEthernet0/0/1        2     up    9000  00:11:22:33:44:56

# 查看详细接口信息
vppctl show interface TenGigabitEthernet0/0/0

# 示例输出：
# Interface TenGigabitEthernet0/0/0
#   Admin state: up
#   Link state: up
#   MTU: 9000
#   Flags: featured, enabled, managed, Loopback
#   Hardware path: /dev/dpdk0
#   Current device setup:
#     RX queues: 4, RX desc: 1024
#     TX queues: 4, TX desc: 1024
#   Traffic stats:
#     Packets: 1234567890
#     Bytes: 987654321098
#     Drops: 1234
#     Errors: 0

# 查看接口地址
vppctl show interface address

# 示例输出：
# TenGigabitEthernet0/0/0 (up):
#   L3 10.0.0.1/24
#   L3 192.168.1.1/24
# TenGigabitEthernet0/0/1 (up):
#   L3 172.16.0.1/16
```

### 2.3 线程与 Worker

```bash
# 查看所有线程
vppctl show threads

# 示例输出：
#   Name          Type       CPU   Pin  Pids   Polls    Suspends
#   vpp_main      active       0     y     1    123456        0
#   vpp_worker_0  active       1     y     2    789012      100
#   vpp_worker_1  active       2     y     3    789012      150
#   vpp_worker_2  active       3     y     4    789012       50
#   vpp_worker_3  active       4     y     5    789012       75
#   vpp_stats     active       6     n     6     12345        0

# 查看 worker 负载
vppctl show threads verbose

# 示例输出：
# Thread 1 (vpp_worker_0):
#   CPU utilization: 85%
#   Queue 0 depth: 64/1024
#   Packets processed: 1234567890
#   Clock cycles: 9876543210
#   Avg latency: 120 ns
```

### 2.4 路由表

```bash
# 查看 IPv4 路由表
vppctl show ip fib

# 示例输出：
# Table 0 (default):
# Destination         Prefix         南下接口       Next Hop         Outbound     Last Update
# 0.0.0.0/0            default        local0        10.0.0.254       TenGigabitEthernet0/0/0  15 days
# 10.0.0.0/24          24             local0        10.0.0.1         TenGigabitEthernet0/0/0  15 days
# 192.168.1.0/24       24             local0        192.168.1.1      TenGigabitEthernet0/0/1  10 days

# 查看 IPv6 路由表
vppctl show ip6 fib

# 查看特定路由
vppctl show ip fib 10.0.0.0/24

# 查看 ARP 表
vppctl show ip arp

# 示例输出：
# Time            Interface           IP            MAC               State
# 15:23:45.123    TenGigabitEthernet0/0/0  10.0.0.254  00:11:22:33:44:55  static
# 15:23:44.456    TenGigabitEthernet0/0/1  192.168.1.100  00:22:33:44:55:66  dynamic
```

### 2.5 邻居与 NDP

```bash
# 查看 IPv6 邻居表
vppctl show ip6 neighbor

# 示例输出：
# Time            Interface           IP            MAC               State
# 15:23:45.123    TenGigabitEthernet0/0/0  fe80::1   00:11:22:33:44:55  router
# 15:23:44.456    TenGigabitEthernet0/0/0  ff02::1   01:00:5e:00:00:01  multicast

# 查看 NDP 缓存
vppctl show ip6 nd

# 查看 reflexive 邻居（反向路径）
vppctl show ip arp reflexive
```

## 3. Stats API

### 3.1 Stats Socket

```bash
# 查看 stats API 内容
# VPP 将统计信息暴露到 /run/vpp/stats.sock

# 使用 vpp-api-cli 读取
vpp-api--cli read /run/vpp/stats.sock

# 示例输出：
# /sys/node/ram
#   free: 24576
#   used: 8192
# /netinterface
#   /TenGigabitEthernet0/0/0
#     /rx
#       /packets: 1234567890
#       /bytes: 987654321098
#       /drops: 1234
#     /tx
#       /packets: 2345678901
#       /bytes: 876543210987
```

### 3.2 常用统计类别

```bash
# 系统统计
vppctl show sys stats

# 接口统计
vppctl show interface stats

# 示例输出：
# Interface: TenGigabitEthernet0/0/0
#   rx:
#     packets: 1234567890
#     bytes: 987654321098
#     multicast: 12345
#     drops: 1234
#     errors: 0
#     nobroadcast: 5678
#   tx:
#     packets: 2345678901
#     bytes: 876543210987
#     drops: 0
#     errors: 0

# 内存统计
vppctl show memory

# 示例输出：
# Memory:
#   Main heap size: 1073741824 bytes (1 GB)
#   Main heap used: 536870912 bytes (512 MB)
#   Main heap free: 536870912 bytes (512 MB)
#   Buffers: 262144 (size 2048 bytes each)
#   Buffer memory: 536870912 bytes
```

### 3.3 程序化读取 Stats

```python
#!/usr/bin/env python3
"""读取 VPP stats API 的 Python 示例"""

import socket
import struct
import json

STATS_SOCKET = "/run/vpp/stats.sock"

def read_stats():
    """从 VPP stats socket 读取统计信息"""
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(STATS_SOCKET)

    # 发送请求
    request = b"\x00" * 64  # API message
    sock.send(request)

    # 读取响应
    data = b""
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        data += chunk

    sock.close()
    return parse_stats(data)

def parse_stats(data):
    """解析 binary stats 数据"""
    # VPP stats 使用 binary format
    # 这里简化处理，实际应参考 vpp-api-cli 源码
    stats = {}

    # 解析接口统计
    offset = 0
    while offset < len(data):
        # 读取 key 长度和内容
        key_len = struct.unpack("I", data[offset:offset+4])[0]
        offset += 4

        if key_len == 0:
            break

        key = data[offset:offset+key_len].decode("utf-8")
        offset += key_len

        # 读取 value
        value = struct.unpack("Q", data[offset:offset+8])[0]
        offset += 8

        stats[key] = value

    return stats

def get_interface_stats(interface_name):
    """获取特定接口的统计"""
    stats = read_stats()

    prefix = f"/netinterface/{interface_name}"
    result = {}

    for key, value in stats.items():
        if key.startswith(prefix):
            result[key.replace(prefix + "/", "")] = value

    return result

if __name__ == "__main__":
    # 获取 TenGigabitEthernet0/0/0 的统计
    stats = get_interface_stats("TenGigabitEthernet0/0/0")
    print(json.dumps(stats, indent=2))
```

### 3.4 统计监控脚本

```bash
#!/bin/bash
# vpp_stats_monitor.sh - 监控 VPP 统计信息

STATS_SOCKET="/run/vpp/stats.sock"
INTERVAL=1

echo "VPP Statistics Monitor"
echo "======================"
echo "Press Ctrl+C to exit"
echo ""

while true; do
    clear
    echo "Time: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""

    # 读取系统统计
    echo "System Stats:"
    vpp-api--cli read $STATS_SOCKET | grep -E "^/sys/" | head -5
    echo ""

    # 读取接口统计
    echo "Interface Stats:"
    vpp-api-cli read $STATS_SOCKET | grep -E "^/netinterface/" | head -10
    echo ""

    # CPU 使用率
    echo "CPU Usage:"
    vppctl show threads | grep -E "vpp_worker" | awk '{print $1, $4}'
    echo ""

    sleep $INTERVAL
done
```

## 4. 调试命令

### 4.1 包追踪 (Packet Tracing)

```bash
# 启用包追踪
vppctl trace add dpdk-input 100

# 上述命令追踪 dpdk-input node 的前 100 个包

# 查看追踪结果
vppctl show trace

# 示例输出：
# ----------------------- Trace buffer -----------------------
# Packet 0:
#   Node: dpdk-input
#   Time: 15:23:45.123
#   Buffer: 0x7f8a9c000
#   Length: 64 bytes
#   Data: 0x00112233445566778899aabbccddeeff...
#   Next node: ethernet-input
# -----------------------------------------------------------

# 清除追踪缓冲
vppctl clear trace

# 保存追踪结果
vppctl exec "show trace" > /tmp/vpp_trace.txt
```

### 4.2 错误与 Drop 追踪

```bash
# 查看所有节点的错误计数
vppctl show errors

# 示例输出：
# Node                  Code                    Count
# ----------------------------------------------------------------
# dpdk-input            RX_NO_BUF               1234
# dpdk-input            RX_BAD_LEN               567
# ip4-lookup            FIB_MISS                8901
# ip4-rewrite           ADJ_MISS                 234

# 查看特定接口的 drops
vppctl show interface TenGigabitEthernet0/0/0 drops

# 示例输出：
# Interface drops for TenGigabitEthernet0/0/0:
#   Software drops:
#     Buffer allocation failure: 0
#     Transmit queue full: 123
#     Checksum error: 45
#   Hardware drops:
#     FIFO overflow: 0
#     Descriptor error: 0

# 查看 buffer 状态
vppctl show buffer

# 示例输出：
# Buffer pools:
#   Default:
#     Size: 2048 bytes
#     Count: 262144
#     Used: 32768 (12.5%)
#     Free: 229376
```

### 4.3 运行时调试

```bash
# 查看 node 图
vppctl show graph

# 示例输出：
# Node graph:
#   0: dpdk-input
#      next[0]: ethernet-input
#   1: ethernet-input
#      next[0]: ip4-input
#      next[1]: ip6-input
#   2: ip4-input
#      next[0]: ip4-lookup
#      next[1]: error-drop
#   ...

# 查看某个 node 的详细信息
vppctl show node ip4-lookup

# 示例输出：
# Node: ip4-lookup
#   Index: 5
#   Type: internal
#   Runtime:
#     Active: 4
#     Avg per call: 123 cycles
#     Total calls: 1234567890
#     Total packets: 1234567890

# 查看 dispatch 统计
vppctl show dispatch stats

# 示例输出：
# Node                Count        Avg     Total   Suspends
# ----------------------------------------------------------------
# dpdk-input          1234567890   64       789234567890  0
# ethernet-input     1234567890   64       789234567890  0
# ip4-lookup         1234567890   64       789234567890  1
```

### 4.4 Hexdump 与包查看

```bash
# 查看包的十六进制内容
vppctl show buffer 12345 verbose

# 示例输出：
# Buffer 12345:
#   Phys addr: 0x7f8a9c000
#   Size: 2048 bytes
#   Used: 64 bytes
#   Metadata:
#     Ref count: 1
#     Alloc thread: worker_0
#   Data (64 bytes):
#   0x0000: 4500 0040 0001 0000 4006 a1c7 0a00 0001
#   0x0010: c0a8 0101 04d0 0050 1234 5678 9abc def0
#   0x0020: 5018 2000 a1f2 0000 0101 080a 0001 2345
#   0x0030: 6789 0000 0000 0000 0000 0000 0000 0000

# 查看最近处理的数据包
vppctl exec "show buffers" | tail -50
```

## 5. 批量操作与脚本

### 5.1 批量配置接口

```bash
# 一次性配置多个接口
vppctl << 'EOF'
set interface state TenGigabitEthernet0/0/0 up
set interface state TenGigabitEthernet0/0/1 up
set interface state TenGigabitEthernet0/0/2 up
set interface state TenGigabitEthernet0/0/3 up
set interface ip address TenGigabitEthernet0/0/0 10.0.0.1/24
set interface ip address TenGigabitEthernet0/0/1 10.0.1.1/24
set interface ip address TenGigabitEthernet0/0/2 10.0.2.1/24
set interface ip address TenGigabitEthernet0/0/3 10.0.3.1/24
set interface mtu 9000 TenGigabitEthernet0/0/0
set interface mtu 9000 TenGigabitEthernet0/0/1
set interface mtu 9000 TenGigabitEthernet0/0/2
set interface mtu 9000 TenGigabitEthernet0/0/3
EOF
```

### 5.2 自动化运维脚本

```bash
#!/bin/bash
# vpp_health_check.sh - VPP 健康检查脚本

VPPCTL="vppctl"
EMAIL="admin@example.com"

echo "VPP Health Check Report"
echo "======================="
echo "Time: $(date)"
echo ""

# 检查 VPP 进程
echo "1. Process Status:"
if pgrep -x vpp > /dev/null; then
    echo "   [OK] VPP is running"
    PID=$(pgrep -x vpp)
    echo "   PID: $PID"
else
    echo "   [FAIL] VPP is not running!"
fi
echo ""

# 检查接口状态
echo "2. Interface Status:"
for iface in $(vppctl show interface | awk '/^[A-Z]/{print $1}'); do
    state=$(vppctl show interface $iface | grep "Link state" | awk '{print $3}')
    if [ "$state" == "up" ]; then
        echo "   [OK] $iface is up"
    else
        echo "   [WARN] $iface is $state"
    fi
done
echo ""

# 检查错误计数
echo "3. Error Statistics:"
errors=$(vppctl show errors | tail -n +3 | awk '{sum += $3} END {print sum}')
if [ "$errors" -gt 0 ]; then
    echo "   [WARN] Total errors: $errors"
    vppctl show errors | tail -10
else
    echo "   [OK] No errors detected"
fi
echo ""

# 检查 CPU 使用率
echo "4. Worker CPU Usage:"
vppctl show threads | grep vpp_worker
echo ""

# 检查内存使用
echo "5. Memory Usage:"
vppctl show memory | grep -E "used|free"
echo ""

# 检查丢包
echo "6. Packet Drops:"
drops=$(vppctl show interface stats | grep -i drops | awk '{sum += $2} END {print sum}')
if [ "$drops" -gt 0 ]; then
    echo "   [WARN] Total drops: $drops"
else
    echo "   [OK] No drops detected"
fi
```

### 5.3 性能数据收集

```bash
#!/bin/bash
# vpp_perf_collect.sh - 性能数据收集

OUTPUT_DIR="/var/log/vpp/perf"
DATE=$(date +%Y%m%d_%H%M%S)
INTERVAL=60  # 60秒采样

mkdir -p $OUTPUT_DIR

while true; do
    TIMESTAMP=$(date +%s)

    # 收集接口统计
    {
        echo "=== Timestamp: $TIMESTAMP ==="
        echo "--- Interface Stats ---"
        vppctl show interface stats
        echo ""
        echo "--- Thread Stats ---"
        vppctl show threads
        echo ""
        echo "--- Node Dispatch Stats ---"
        vppctl show node
    } >> $OUTPUT_DIR/interface_$DATE.log

    # 收集系统统计
    {
        echo "=== Timestamp: $TIMESTAMP ==="
        echo "--- Memory ---"
        vppctl show memory
        echo ""
        echo "--- Buffers ---"
        vppctl show buffer
    } >> $OUTPUT_DIR/system_$DATE.log

    sleep $INTERVAL
done
```

### 5.4 配置备份与恢复

```bash
#!/bin/bash
# vpp_config_backup.sh - 配置备份

BACKUP_DIR="/var/backups/vpp"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# 备份当前配置
vppctl exec "show running" > $BACKUP_DIR/running_config_$DATE.txt

# 备份 startup 配置
cp /etc/vpp/startup.conf $BACKUP_DIR/startup_$DATE.conf

# 创建备份元数据
cat > $BACKUP_DIR/backup_$DATE.meta << EOF
Backup Time: $(date)
VPP Version: $(vppctl show version | head -1)
Hostname: $(hostname)
EOF

# 压缩备份
tar czf $BACKUP_DIR/vpp_backup_$DATE.tar.gz \
    $BACKUP_DIR/running_config_$DATE.txt \
    $BACKUP_DIR/startup_$DATE.conf \
    $BACKUP_DIR/backup_$DATE.meta

# 清理临时文件
rm -f $BACKUP_DIR/running_config_$DATE.txt \
      $BACKUP_DIR/startup_$DATE.conf \
      $BACKUP_DIR/backup_$DATE.meta

echo "Backup saved to: $BACKUP_DIR/vpp_backup_$DATE.tar.gz"
```

## 6. gRPC API 运维

### 6.1 gRPC 接口配置

```bash
# startup.conf 中启用 gRPC
vpp {
    # gRPC 配置文件路径
    # grpc config /etc/vpp/grpc.conf

    # gRPC 端口（默认 5001）
    # grpc-port 5001
}

# 查看 gRPC 服务状态
vppctl show grpc

# 示例输出：
# gRPC Status: enabled
# Port: 5001
# Connections: 3
# Requests: 12345
```

### 6.2 gRPC API 调用示例

```python
#!/usr/bin/env python3
"""使用 gRPC API 管理 VPP"""

import grpc
from vpp_api import vpp_pb2, vpp_pb2_grpc

# 连接到 VPP gRPC 服务
channel = grpc.insecure_channel('localhost:5001')
stub = vpp_pb2_grpc.VPPAPIStub(channel)

# 创建接口
def create_interface(name, mac_address):
    req = vpp_pb2.CreateLoopbackRequest(
        interface={
            "name": name,
            "mac_address": mac_address
        }
    )
    response = stub.CreateLoopback(req)
    return response.interface_index

# 设置接口状态
def set_interface_state(interface_index, admin_up=True):
    req = vpp_pb2.SwInterfaceSetFlagsRequest(
        sw_if_index=interface_index,
        admin_up=admin_up
    )
    response = stub.SwInterfaceSetFlags(req)
    return response.retval

# 添加 IP 地址
def add_ip_address(interface_index, ip_address, prefix_length):
    req = vpp_pb2.VnetInterfaceIPAddDelRequest(
        sw_if_index=interface_index,
        is_add=True,
        address=ip_address,
        prefix_length=prefix_length
    )
    response = stub.VnetInterfaceIPAddDel(req)
    return response.retval

# 获取接口列表
def list_interfaces():
    req = vpp_pb2.SwInterfaceDumpRequest()
    response = stub.SwInterfaceDump(req)
    return response.interface

if __name__ == "__main__":
    # 列出所有接口
    for iface in list_interfaces():
        print(f"{iface.interface_name}: {iface.admin_state}")
```

### 6.3 远程运维最佳实践

```bash
# 1. 使用 SSH 隧道连接远程 VPP
ssh -L 5001:localhost:5001 vpp-host

# 2. 使用 TLS 加密的 gRPC
# 在 startup.conf 中配置 TLS
vpp {
    grpc {
        tls-ca-cert /etc/vpp/tls/ca.crt
        tls-server-cert /etc/vpp/tls/server.crt
        tls-server-key /etc/vpp/tls/server.key
    }
}

# 3. 使用 API key 认证
cat > ~/.vpp_api_key << EOF
Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...
EOF

# 4. 通过代理连接
HTTPS_PROXY=http://proxy:8080 vppctl -r remote-host:5001
```
