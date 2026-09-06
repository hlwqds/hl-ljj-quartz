---
title: "VPP 深入探讨 ch36：高可用与故障切换"
date: 2026-04-16 10:46:00
tags: [vpp, high-availability, failover, VRRP, BFD, redundancy, bonding, load-balancing]
description: "深入解析 VPP 高可用与故障切换：VRRP、接口冗余、BFD 检测、链路聚合、负载均衡集群与故障切换机制"
---

# VPP 深入探讨 ch36：高可用与故障切换

> [!abstract] 核心要点
> 高可用是生产网络的关键需求。本章详解 VPP 高可用架构：VRRP 冗余、接口链路聚合、BFD 检测、故障切换机制与负载均衡集群。

## 1. 高可用架构

### 1.1 HA 架构概述

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP 高可用架构                            │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                   Layer 2 HA                         │   │
│   │                                                      │   │
│   │   ┌─────────────┐     ┌─────────────┐              │   │
│   │   │   VPP-01    │─────│   VPP-02    │              │   │
│   │   │  (Primary)  │     │  (Backup)   │              │   │
│   │   └──────┬──────┘     └──────┬──────┘              │   │
│   │          │                    │                     │   │
│   │          └────────┬───────────┘                     │   │
│   │                   │                                 │   │
│   │              ┌────▼────┐                           │   │
│   │              │ Bond/   │                            │   │
│   │              │ LACP   │                            │   │
│   │              └────┬────┘                           │   │
│   └───────────────────┼───────────────────────────────┘   │
│                        │                                    │
│   ┌───────────────────┼───────────────────────────────┐   │
│   │                   Layer 3 HA                        │   │
│   │                                                      │   │
│   │   ┌─────────────┐     ┌─────────────┐              │   │
│   │   │   VIP       │◄────│   VRRP      │              │   │
│   │   │ 10.0.0.100  │     │  Group 1    │              │   │
│   │   └──────┬──────┘     └──────┬──────┘              │   │
│   │          │                    │                     │   │
│   │          ▼                    ▼                     │   │
│   │   ┌─────────────┐     ┌─────────────┐              │   │
│   │   │   VPP-01    │     │   VPP-02    │              │   │
│   │   │  Priority   │     │  Priority   │              │   │
│   │   │    150      │     │    100      │              │   │
│   │   └─────────────┘     └─────────────┘              │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                              │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                  BFD Detection                        │   │
│   │                                                      │   │
│   │   VPP-01 ◄──────── BFD ────────► VPP-02            │   │
│   │        ◄─────── 100ms ────────►                     │   │
│   │                                                      │   │
│   │   Session State: Up                                  │   │
│   │   Detection Time: 300ms (3 * 100ms)                 │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 HA 模式

| 模式              | 描述                       | 适用场景   | 切换时间 |
| ----------------- | -------------------------- | ---------- | -------- |
| **Active-Backup** | 主备模式，一台活跃其余备份 | 简单部署   | 秒级     |
| **Active-Active** | 多台同时活跃，负载均衡     | 高吞吐需求 | 毫秒级   |
| **Load-Balancer** | VIP 流量分担到多个节点     | 入口网关   | 毫秒级   |
| **Route-Health**  | 基于路由的 HA，宣告 VIP    | L3 部署    | 秒级     |

### 1.3 HA 设计原则

```
┌─────────────────────────────────────────────────────────────┐
│                   VPP HA 设计原则                           │
│                                                              │
│   1. 无单点故障                                              │
│      - 双机或多机部署                                        │
│      - 独立电源和网络路径                                     │
│                                                              │
│   2. 状态同步                                                │
│      - 连接状态实时同步                                       │
│      - NAT 映射同步                                          │
│      - ARP/路由表同步                                         │
│                                                              │
│   3. 快速检测                                                │
│      - BFD 毫秒级故障检测                                     │
│      - 心跳保活                                              │
│      - 阈值合理的超时                                        │
│                                                              │
│   4. 快速恢复                                                │
│      - 自动故障切换                                          │
│      - VIP 快速迁移                                          │
│      - 流量快速重路由                                         │
│                                                              │
│   5. 零丢包切换                                             │
│      - 同步机制保证状态一致                                   │
│      - 平滑切换流程                                          │
│      - Preemption 机制                                      │
└─────────────────────────────────────────────────────────────┘
```

## 2. VRRP 冗余

### 2.1 VRRP 配置

```bash
# 在 VPP 中配置 VRRP
vppctl << 'EOF'
# 创建 VRRP 虚拟路由器
vrrp create vrid 100

# 配置虚拟 IP
vrrp vrid 100 virtual-ip 10.0.0.100/24

# 配置物理接口
vrrp vrid 100 interface TenGigabitEthernet0/0/0

# 设置优先级（主节点设置更高）
vrrp vrid 100 priority 150

# 启用抢占（可选）
vrrp vrid 100 preempt

# 配置心跳间隔（秒）
vrrp vrid 100 advertisement-interval 1

# 配置优先级递减（用于跟踪接口）
vrrp vrid 100 tracking TenGigabitEthernet0/0/0 priority-delta 50

# 启用 VRRP
vrrp vrid 100 enable
EOF

# 查看 VRRP 状态
vppctl show vrrp

# 示例输出：
# VRRP Virtual Routers:
#   VRID 100:
#     State: Master
#     Virtual IP: 10.0.0.100/24
#     Interface: TenGigabitEthernet0/0/0
#     Priority: 150 (Current: 150)
#     Master Interval: 1s
#     Uptime: 15 days 5 hours
#     State transitions: 2
```

### 2.2 VRRP 接口跟踪

```bash
# 配置接口跟踪
vppctl << 'EOF'
# 跟踪多个接口
vrrp vrid 100 tracking TenGigabitEthernet0/0/0
vrrp vrid 100 tracking TenGigabitEthernet0/0/1

# 跟踪物理接口状态变化，自动降低优先级
# 格式：interface <name> priority-delta <delta>
vrrp vrid 100 tracking interface TenGigabitEthernet0/0/0 priority-delta 30
vrrp vrid 100 tracking interface TenGigabitEthernet0/0/1 priority-delta 30

# 优先级计算：
# Base Priority: 150
# Interface eth0 down: 150 - 30 = 120
# Interface eth1 down: 120 - 30 = 90
# Backup 节点默认优先级: 100
# 120 > 100，所以仍为 Master
# 90 < 100，切换为 Backup
EOF

# 查看跟踪状态
vppctl show vrrp verbose

# 示例输出：
# VRID 100:
#   State: Master
#   Tracked interfaces:
#     TenGigabitEthernet0/0/0: up (priority-delta: 30, effective)
#     TenGigabitEthernet0/0/1: up (priority-delta: 30, effective)
#   Effective Priority: 90
#   Backup Priority: 100
```

### 2.3 VRRP 安全

```bash
# 配置 VRRP 认证
vppctl << 'EOF'
# 设置认证类型
vrrp vrid 100 authentication type ah

# AH (Authentication Header) 认证
vrrp vrid 100 authentication data SecurePassword123

# 或者使用简单密码认证
vrrp vrid 100 authentication type simple
vrrp vrid 100 authentication data mysecret
EOF

# 配置 VRRP 版本
vppctl << 'EOF'
# VRRPv2 (IPv4)
vrrp vrid 100 version 2

# VRRPv3 (IPv4 + IPv6)
vrrp vrid 100 version 3
EOF

# 查看 VRRP 安全统计
vppctl show vrrp security

# 示例输出：
# VRRP Security:
#   VRID 100:
#     Authentication Type: AH
#     Authentication Data: ****
#     Failed Authentications: 0
#     Invalid Packets: 0
```

## 3. BFD (Bidirectional Forwarding Detection)

### 3.1 BFD 配置

```bash
# 启用 BFD
vppctl << 'EOF'
# 全局启用 BFD
bfd enable
EOF

# 配置 BFD 会话
vppctl << 'EOF'
# 创建 BFD UDP 会话
bfd session add \
    peer 192.168.1.100 \
    source 192.168.1.1 \
    ttl 255 \
    required-hi 300 \
    desired-hi 100 \
    demand

# 配置 BFD 认证
bfd auth add \
    peer 192.168.1.100 \
    type keyed-sha1 \
    key-id 1 \
    key mysecretkey
EOF

# 查看 BFD 会话
vppctl show bfd

# 示例输出：
# BFD Sessions:
#   Peer: 192.168.1.100
#     Source: 192.168.1.1
#     State: Up
#     Detection Time: 300ms (3 * 100ms)
#     Echo Interval: 0ms (disabled)
#     Uptime: 15 days 5 hours
#     Auth: keyed-sha1 (key-id: 1)
```

### 3.2 BFD 与路由联动

```bash
# 配置 BFD 监控的路由
vppctl << 'EOF'
# 添加静态路由并关联 BFD
ip route add 192.168.100.0/24 via 192.168.1.100 TenGigabitEthernet0/0/0
bfd route add 192.168.100.0/24 peer 192.168.1.100

# 路由与 BFD 联动：
# - BFD 故障时自动删除路由
# - BFD 恢复时自动恢复路由
EOF

# 查看 BFD 监控的路由
vppctl show bfd routes

# 示例输出：
# BFD-Monitored Routes:
#   192.168.100.0/24 via 192.168.1.100
#     BFD State: Up
#     Route State: Active
#     Last BFD State Change: 15:30:00
```

### 3.3 BFD 与 VRRP 联动

```bash
# 配置 BFD 监控 VRRP 主节点
vppctl << 'EOF'
# 为 VRRP 启用 BFD 检测
vrrp vrid 100 bfd peer 192.168.1.100

# BFD 检测到故障时快速切换
# 切换时间可达到 300ms 以内
EOF

# 查看 VRRP BFD 状态
vppctl show vrrp bfd

# 示例输出：
# VRRP BFD Status:
#   VRID 100:
#     BFD Peer: 192.168.1.100
#     BFD State: Up
#     VRRP State: Master
#     Fallover Timer: 300ms
```

### 3.4 BFD 参数调优

```bash
# BFD 参数说明

# Required Min Heartbeat Interval (.required-hi)
# - 检测端要求的最小接收间隔 (ms)
# - 推荐: 300ms (高可靠性)

# Desired Min Heartbeat Interval (desired-hi)
# - 本端期望的发送间隔 (ms)
# - 推荐: 100ms (快速检测)

# Detection Time (hi * multiplier)
# - 检测时间 = 间隔 * 乘数
# - 300ms * 3 = 900ms (最长检测时间)

# BFD 参数对比

| 场景 | desired-hi | required-hi | multiplier | 检测时间 |
|------|-----------|-------------|------------|----------|
| 毫秒级 | 50ms | 150ms | 3 | 450ms |
| 快速 | 100ms | 300ms | 3 | 900ms |
| 标准 | 200ms | 600ms | 3 | 1.8s |
| 保守 | 500ms | 1500ms | 3 | 4.5s |
```

## 4. 链路聚合

### 4.1 LACP 配置

```bash
# 创建 Bond 接口
vppctl << 'EOF'
# 创建 LACP bond (mode 4)
create bond interface lacp

# 配置 bond 参数
set bond mode lacp
set bond田径运动 Load Balance

# 添加成员接口
set bond TenGigabitEthernet0/0/0 slave
set bond TenGigabitEthernet0/0/1 slave

# 查看 bond 状态
show bond
EOF

# 示例输出：
# Bond Interface: bond0
#   Mode: LACP (802.3ad)
#   Load Balance: Layer 3+4
#   Members: 2 active, 0 standby
#     TenGigabitEthernet0/0/0: active (port 1)
#     TenGigabitEthernet0/0/1: active (port 2)
#   LACPDU Interval: 1s
#   System ID: 00:11:22:33:44:55
```

### 4.2 负载均衡模式

```bash
# 配置 bond 负载均衡模式
vppctl << 'EOF'
# Layer 2 (MAC) 负载均衡
set bond load-balance mac

# Layer 3 (IP) 负载均衡
set bond load-balance ip

# Layer 3+4 (IP + Port) 负载均衡（推荐）
set bond load-balance ip-l34

# Layer 2+3 负载均衡
set bond load-balance l2
EOF

# 查看负载均衡统计
vppctl show bond balance

# 示例输出：
# Bond Load Balance (ip-l34):
#   Member                 Packets    Bytes
#   TenGigabitEthernet0/0/0   123456    98765432
#   TenGigabitEthernet0/0/1   123789    99876543
#   Balance ratio: 1.00 (good)
```

### 4.3 Bond 故障检测

```bash
# 配置 Bond MII (Media Independent Interface) 监控
vppctl << 'EOF'
# 启用 MII 监控
set bond monitor enable

# 监控间隔 (ms)
set bond monitor interval 100

# 上行链路检测次数
set bond monitor carrier up 5
set bond monitor carrier down 2
EOF

# 查看 bond 详细状态
vppctl show bond verbose

# 示例输出：
# Bond Interface: bond0
#   Mode: LACP
#   Monitor: enabled (MII, 100ms)
#   Carrier Status: up
#   Active Members: 2
#   Standby Members: 0
#
#   Member Details:
#     TenGigabitEthernet0/0/0:
#       State: active
#       Port ID: 1
#       Carrier: up
#       MII Status: up
#       Last Carrier Change: 5 days ago
#
#     TenGigabitEthernet0/0/1:
#       State: active
#       Port ID: 2
#       Carrier: up
#       MII Status: up
#       Last Carrier Change: 5 days ago
```

### 4.4 Bond + VRRP 组合

```bash
# 在 Bond 接口上配置 VRRP
vppctl << 'EOF'
# 1. 创建 bond
create bond interface lacp
set bond mode lacp
set bond load-balance ip-l34
set bond TenGigabitEthernet0/0/0 slave
set bond TenGigabitEthernet0/0/1 slave

# 2. 在 bond 上配置 IP
set interface ip address bond0 10.0.0.1/24

# 3. 在 bond 上配置 VRRP
vrrp create vrid 100
vrrp vrid 100 virtual-ip 10.0.0.100/24
vrrp vrid 100 interface bond0
vrrp vrid 100 priority 150
vrrp vrid 100 enable

# 4. 启用 BFD 加速故障检测
vrrp vrid 100 bfd peer 10.0.0.2
EOF

# 查看配置
vppctl show vrrp
vppctl show bond
```

## 5. 故障切换实现

### 5.1 故障切换流程

```
┌─────────────────────────────────────────────────────────────┐
│                   VPP 故障切换流程                           │
│                                                              │
│   检测阶段:                                                   │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                                                      │   │
│   │   BFD Session fails ──────────────────────────────┐  │   │
│   │   or                                             │  │   │
│   │   Interface carrier down ──────────────────────┐  │   │
│   │   or                                             │  │   │
│   │   VRRP advertisement timeout ─────────────────┐  │  │   │
│   │                                                  │  │   │
│   └──────────────────────────────────────────────────┼──┘   │
│                                                      │       │
│   决策阶段:                                            │       │
│   ┌────────────────────▼──────────────────────────────┐   │
│   │                                                      │   │
│   │   Backup 节点:                                      │   │
│   │   - 等待 Master Down 计时器 (3 * adv_interval)     │   │
│   │   - 发送 VRRP Advertisement (priority 150)         │   │
│   │   - 成为新的 Master                                 │   │
│   │                                                      │   │
│   └─────────────────────────────────────────────────────┘   │
│                              │                               │
│   切换阶段:                          │                       │
│   ┌───────────────────────────────▼──────────────────────┐   │
│   │                                                      │   │
│   │   1. 接管 VIP (ARP/GARP)                             │   │
│   │   2. 状态同步 (连接表、NAT、ACL)                     │   │
│   │   3. 路由更新                                        │   │
│   │   4. 通知上层 (BGP/邻居)                             │   │
│   │   5. 流量切换                                        │   │
│   │                                                      │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                              │
│   恢复阶段:                                                   │
│   ┌─────────────────────────────────────────────────────┐   │
│   │                                                      │   │
│   │   原 Master 恢复:                                    │   │
│   │   - BFD session up                                  │   │
│   │   - 发送 VRRP (priority 150, preempt)               │   │
│   │   - 抢回 Master 角色                                 │   │
│   │   - 重新同步状态                                     │   │
│   │                                                      │   │
│   └─────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

### 5.2 状态同步

```bash
# 配置状态同步
vppctl << 'EOF'
# 启用连接表同步
stn sync enable
stn mode active-active

# 配置同步目标
stn add peer 192.168.1.100
stn add peer 192.168.1.101

# NAT 同步
nat44 sync enable
nat66 sync enable

# 配置同步间隔
stn sync interval 100  # ms
EOF

# 查看同步状态
vppctl show stn

# 示例输出：
# Stateful NAT (STN) Configuration:
#   Mode: Active-Active
#   Sync Enabled: yes
#   Sync Interval: 100ms
#
# Peers:
#   192.168.1.100: connected, state: synced
#   192.168.1.101: connected, state: synced
#
# Sync Statistics:
#   Sessions synced: 1234567
#   Bytes synced: 987654321
#   Sync errors: 0
```

### 5.3 双机热备脚本

```bash
#!/bin/bash
# vpp_ha_monitor.sh - VPP HA 监控脚本

PRIMARY_VIP="10.0.0.100"
PRIMARY_IP="10.0.0.1"
BACKUP_IP="10.0.0.2"
VPP_CLI="vppctl"

STATE_FILE="/var/run/vpp_ha_state"
LOG_FILE="/var/log/vpp_ha.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a $LOG_FILE
}

get_state() {
    cat $STATE_FILE 2>/dev/null || echo "unknown"
}

set_state() {
    echo "$1" > $STATE_FILE
}

check_bfd() {
    # 检查 BFD 状态
    bfd_state=$($VPP_CLI show bfd | grep "State:" | awk '{print $2}')
    if [ "$bfd_state" = "Up" ]; then
        return 0
    else
        return 1
    fi
}

check_vrrp() {
    # 检查 VRRP 状态
    vrrp_state=$($VPP_CLI show vrrp | grep "State:" | awk '{print $2}')
    if [ "$vrrp_state" = "Master" ]; then
        return 0
    else
        return 1
    fi
}

do_failover() {
    log "Initiating failover..."

    # 1. 通知 BGP/路由协议
    # (实现取决于使用的路由协议)

    # 2. 发送 GARP
    $VPP_CLI << EOF
send garp TenGigabitEthernet0/0/0 $PRIMARY_VIP
EOF

    # 3. 更新状态
    set_state "master"

    # 4. 通知
    # mail -s "[VPP HA] Failover completed" admin@example.com

    log "Failover completed"
}

# 主循环
while true; do
    current_state=$(get_state)

    if check_bfd; then
        if check_vrrp; then
            if [ "$current_state" != "master" ]; then
                log "Becoming master"
                set_state "master"
            fi
        else
            if [ "$current_state" = "master" ]; then
                log "Lost VRRP master, but BFD is up, maintaining master"
            fi
        fi
    else
        # BFD 故障
        if [ "$current_state" = "master" ]; then
            log "BFD down, releasing master"
            set_state "backup"
        fi
    fi

    sleep 1
done
```

### 5.4 健康检查与自动恢复

```bash
#!/bin/bash
# vpp_ha_health_check.sh - HA 健康检查与自动恢复

VIP="10.0.0.100"
CHECK_INTERVAL=5
MAX_RETRIES=3

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 检查 VPP 基本健康
check_vpp_health() {
    if ! vppctl show version > /dev/null 2>&1; then
        return 1
    fi

    # 检查接口
    up_count=$(vppctl show interface | grep -c "up" || echo 0)
    if [ "$up_count" -lt 2 ]; then
        return 1
    fi

    return 0
}

# 检查 VIP 绑定
check_vip() {
    # 检查本地是否有 VIP
    if ip addr show | grep -q "$VIP"; then
        return 0
    else
        return 1
    fi
}

# 主循环
while true; do
    retries=0

    while [ $retries -lt $MAX_RETRIES ]; do
        if check_vpp_health; then
            break
        fi

        log "Health check failed, retry $((retries + 1))/$MAX_RETRIES"
        ((retries++))
        sleep $CHECK_INTERVAL
    done

    if [ $retries -eq $MAX_RETRIES ]; then
        log "CRITICAL: VPP health check failed after $MAX_RETRIES attempts"

        # 尝试重启 VPP
        log "Attempting VPP restart..."
        systemctl restart vpp

        sleep 10

        # 重新检查
        if check_vpp_health; then
            log "VPP restarted successfully"
        else
            log "VPP restart failed, alerting..."
            # 发送告警
            # mail -s "[VPP CRITICAL] Health check failed" admin@example.com
        fi
    fi

    sleep $CHECK_INTERVAL
done
```

## 6. 负载均衡集群

### 6.1 ECMP 配置

```bash
# 配置等价多路径 (ECMP)
vppctl << 'EOF'
# 启用 ECMP
ip6 table add 0

# 添加多条等价路由
ip route add 10.0.0.0/24 via 192.168.1.1 TenGigabitEthernet0/0/0
ip route add 10.0.0.0/24 via 192.168.2.1 TenGigabitEthernet0/0/1
ip route add 10.0.0.0/24 via 192.168.3.1 TenGigabitEthernet0/0/2

# 查看 ECMP
show ip fib
EOF

# 示例输出：
# 10.0.0.0/24
#   via 192.168.1.1 TenGigabitEthernet0/0/0 (weight 1)
#   via 192.168.2.1 TenGigabitEthernet0/0/1 (weight 1)
#   via 192.168.3.1 TenGigabitEthernet0/0/2 (weight 1)
#   ECMP paths: 3
```

### 6.2 NAT 负载均衡

```bash
# 配置 NAT 负载均衡
vppctl << 'EOF'
# 启用 NAT44
nat44 enable

# 配置 NAT 池 (outside 地址)
nat44 address add 203.0.113.1 - 203.0.113.10

# 配置内部服务器
nat44 add address 10.0.0.10 to 203.0.113.100
nat44 add address 10.0.0.11 to 203.0.113.101
nat44 add address 10.0.113.102

# 端口映射
nat44 add static mapping tcp local 10.0.0.10 8080 external 203.0.113.100 80

# 查看 NAT LB
show nat44
EOF

# 配置会话负载均衡 (per-flow)
vppctl << 'EOF'
# 启用会话负载均衡
nat44 load-balancing enable

# 配置后端服务器
nat44 pool add 10.0.0.10
nat44 pool add 10.0.0.11
nat44 pool add 10.0.0.12

# 配置负载均衡规则
nat44 rule add match tcp destination-port 80 pool 10.0.0.10-10.0.0.12
EOF
```

### 6.3 L4 负载均衡 (LB)

```bash
# 创建负载均衡器
vppctl << 'EOF'
# 创建 LB VIP
lb create vip 203.0.113.100:80 protocol tcp

# 添加后端服务器
lb vip 203.0.113.100:80 add 10.0.0.10:8080
lb vip 203.0.113.100:80 add 10.0.0.11:8080
lb vip 203.0.113.100:80 add 10.0.0.12:8080

# 配置负载均衡算法
lb vip 203.0.113.100:80 algorithm round-robin
# 算法选项: round-robin, weighted-round-robin, least-connections

# 配置健康检查
lb health-check ping 10.0.0.10 interval 5 timeout 3
lb health-check ping 10.0.0.11 interval 5 timeout 3
lb health-check ping 10.0.0.12 interval 5 timeout 3

# 启用 VIP
lb vip 203.0.113.100:80 enable
EOF

# 查看 LB 状态
vppctl show lb

# 示例输出：
# Load Balancer:
#   VIP: 203.0.113.100:80 (TCP)
#   Algorithm: round-robin
#   Active Backends: 3
#
#   Backend                  Weight   Active   Connections
#   10.0.0.10:8080            1        yes     1234
#   10.0.0.11:8080            1        yes     1235
#   10.0.0.12:8080            1        yes     1233
#
#   Total: 3702 connections
```

### 6.4 AnyCast 负载均衡

```bash
# 配置 AnyCast
vppctl << 'EOF'
# 添加 AnyCast 地址
ip route add 10.0.100.1/32 via 10.0.0.1 TenGigabitEthernet0/0/0
ip route add 10.0.100.1/32 via 10.0.1.1 TenGigabitEthernet0/0/1

# AnyCast 路由会被 ECMP 自动负载均衡
# 同一区域的流量会走同一路径

# 查看 AnyCast 路由
show ip fib 10.0.100.1
EOF

# 示例输出：
# 10.0.100.1/32
#   Path 1: via 10.0.0.1 TenGigabitEthernet0/0/0 (ECMP weight 1)
#   Path 2: via 10.0.1.1 TenGigabitEthernet0/0/1 (ECMP weight 1)
#   ECMP: yes
```
