---
title: "RDMA 第十九章：RDMA 配置工具——诊断、测试与验证"
date: 2026-04-13
tags:
  [
    rdma,
    tools,
    perftest,
    ibstat,
    ibdevinfo,
    rping,
    ucmatose,
    ibdiagnet,
    ibv_rc_pingpong,
    rdma,
    diagnosis,
  ]
description: "详解 RDMA 常用工具：ibv_rc_pingpong、perftest 性能测试、ibstat/ibdevinfo 设备信息、rping/ucmatose 连接测试、ibdiagnet 网络诊断、perfmon 性能计数器。"
---

> [!abstract] 核心要点
> RDMA 开发和运维需要一套完整的工具链。本章介绍 InfiniBand/RoCE 环境下最常用的诊断和测试工具，包括性能测试工具（perftest）、设备查询工具（ibstat、ibdevinfo）、连接测试工具（rping、ucmatose）、网络诊断工具（ibdiagnet、ibnetdiscover）以及性能监控工具（perfmon）。

---

## 1. 工具链概述

### 1.1 RDMA 工具分类

```
RDMA 工具分类：

  ┌─────────────────────────────────────────────────────────────────────────┐
  │  性能测试                                                              │
  │    perftest      - 带宽/延迟基准测试                                    │
  │    ibv_[rc|ud]_pingpong - 基础连通性测试                               │
  │    rping         - RDMA socket 测试                                    │
  │    ucmatose      - UD/RC 连通性测试                                     │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  设备查询                                                              │
  │    ibstat        - IB 端口状态                                         │
  │    ibdevinfo     - IB 设备详细信息                                      │
  │    ibv_devinfo   - Verbs 设备信息                                      │
  │    ibswitches    - 交换机信息                                          │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  网络诊断                                                              │
  │    ibdiagnet     - 网络诊断和验证                                       │
  │    ibnetdiscover - 网络拓扑发现                                         │
  │    saquery       - Subnet Administrator 查询                          │
  │    smpquery      - Subnet Management 查询                             │
  ├─────────────────────────────────────────────────────────────────────────┤
  │  性能监控                                                              │
  │    perfmon       - 性能计数器监控                                       │
  │    ibtop         - 实时流量监控                                         │
  │    rdma stat     - RDMA 统计信息                                        │
  └─────────────────────────────────────────────────────────────────────────┘
```

### 1.2 安装

```bash
# RDMA tools 通常随 RDMA-Core (rdma-core) 包安装
# Debian/Ubuntu
$ apt-get install rdma-core perftest infiniband-diags

# RHEL/CentOS
$ yum install rdma-core perftest infiniband-diags

# Mellanox OFED (包含完整工具链)
$ yum install mlnx-ofa-tools mlnx-ethtool

# 验证安装
$ which ibv_rc_pingpong
$ which perftest
$ which ibdiagnet
```

---

## 2. 性能测试工具

### 2.1 perftest

perftest 是最常用的 RDMA 性能基准测试工具：

```bash
# perftest 基本用法
$ perftest -d <device> -i <port> [options]

# 常用选项：
#   -d, --ib-dev       指定设备名 (如 mlx5_0)
#   -i, --ib-port      端口号 (默认 1)
#   -s, --size         消息大小 (默认 65536)
#   -n, --iters        迭代次数 (默认 1000)
#   -t, -- tx-depth    发送队列深度
#   -z, --zerobytes   零字节测试 (验证控制路径)
#   -F, --feature      特性 (ecn, pfc, etc.)
#   -o, --output       输出文件
#   -v, --verbose      详细信息
```

#### 带宽测试

```bash
# 测试 RDMA Read 带宽
$ perftest -d mlx5_0 -z -F ecn -s 65536 -n 100000 -t 32 --run_infinitely

# UD 带宽测试
$ perftest -d mlx5_0 -u -s 4096 -n 500000

# RC 带宽测试
$ perftest -d mlx5_0 -c -s 65536 -n 100000

# 参数说明：
#   -z: zerobytes (只测试控制路径)
#   -F ecn: 使用 ECN 拥塞控制
#   -c: RC 模式 (默认)
#   -u: UD 模式
#   -s: 消息大小
#   -n: 迭代次数
#   -t: 发送队列深度
```

#### 延迟测试

```bash
# 测试单侧延迟（需要两台机器）
# 机器 A (接收端)
$ perftest -d mlx5_0 -z

# 机器 B (发送端)
$ perftest -d mlx5_0 -z <B's IP>

# 测试不同消息大小的延迟
$ for size in 4 64 256 1024 4096 65536; do
    perftest -d mlx5_0 -s $size -n 100000 -z
  done

# 测试 RR (Round Robin) 延迟
$ perftest -d mlx5_0 -r -s 64 -n 1000000
```

#### 完整性能测试脚本

```bash
#!/bin/bash
# roce_perf_test.sh - RoCE 性能完整测试

DEV=mlx5_0
PORT=1
IP_REMOTE=192.168.1.100

echo "=== RoCE Performance Test ==="

# 1. 基本信息
echo "[1] Device Info:"
ibv_devinfo -d ${DEV}

# 2. 延迟测试 (不同消息大小)
echo ""
echo "[2] Latency Test:"
for SIZE in 4 64 256 1024 4096 16384 65536; do
    echo -n "  Size ${SIZE}: "
    # 实际测试需要两台机器
    perftest -d ${DEV} -s ${SIZE} -n 10000 -z 2>&1 | \
        grep -oP 'latency=\K[\d.]+'
done

# 3. 带宽测试 (RC)
echo ""
echo "[3] RC Bandwidth Test:"
for SIZE in 64 256 1024 4096 16384 65536 262144; do
    echo -n "  Size ${SIZE}: "
    perftest -d ${DEV} -c -s ${SIZE} -n 50000 -t 32 2>&1 | \
        grep -oP 'BW ave=\K[\d.]+'
done

# 4. UD 带宽测试
echo ""
echo "[4] UD Bandwidth Test:"
perftest -d ${DEV} -u -s 4096 -n 100000 -t 64

# 5. ECN 测试
echo ""
echo "[5] ECN-enabled Test:"
perftest -d ${DEV} -c -F ecn -s 65536 -n 50000
```

### 2.2 ibv_rc_pingpong / ibv_ud_pingpong

基础的 QP 连通性测试工具：

```bash
# RC 模式 Ping-Pong 测试
# 机器 A (服务器)
$ ibv_rc_pingpong -d mlx5_0 -g 0

# 机器 B (客户端)
$ ibv_rc_pingpong -d mlx5_0 -g 0 <A's IP>

# UD 模式 Ping-Pong 测试
$ ibv_ud_pingpong -d mlx5_0 -g 0 <A's IP>

# 参数说明：
#   -d, --device      设备名
#   -g, --gid-index   GID 索引 (0 或 RoCE v2 GID)
#   -s, --size        消息大小
#   -n, --iters       迭代次数

# 示例输出：
#  ------------------------------------------------------------------
#  Remote Address: fe80000000000000:0x7cfe45030fff7d66
#  local address:  fe80000000000000:0x7cfe4503ff0014a
#  PP verb tests: 1base:1
#  65536 bytes in 10000 iterations:  1048.68 usec
#  ------------------------------------------------------------------
```

### 2.3 rping

RDMA socket 风格的测试工具：

```bash
# 服务器模式
$ rping -s -d mlx5_0 -a <server_ip> -C 100

# 客户端模式
$ rping -c -d mlx5_0 -a <server_ip> -C 100

# 参数说明：
#   -s, --server      服务器模式
#   -c, --client      客户端模式
#   -d, --device      设备名
#   -a, --addr        目标地址
#   -C, --count       测试次数

# 测试示例
# Server: $ rping -s -a 192.168.1.10
# Client: $ rping -c -a 192.168.1.10
# Expected: "rdma poll completion: status 0, len 4"
```

### 2.4 ucmatose

简单的 UD/RC 连通性测试：

```bash
# UD 测试
# 服务器
$ ucmatose -S -d mlx5_0

# 客户端
$ ucmatose -C -d mlx5_0 -b <server_ip>

# RC 测试
# 服务器
$ ucmatose -s -d mlx5_0 -R

# 客户端
$ ucmatose -c -d mlx5_0 -b <server_ip> -R

# 参数：
#   -S, -s: 服务器模式
#   -C, -c: 客户端模式
#   -R: RC 模式 (默认 UD)
#   -b: 目标地址
#   -d: 设备名
```

---

## 3. 设备查询工具

### 3.1 ibv_devinfo

查看 Verbs 设备详细信息：

```bash
# 基本用法
$ ibv_devinfo

# 指定设备
$ ibv_devinfo -d mlx5_0

# 字段说明：
#   hca_type:        HCA 类型 (如 MT4119, ConnectX-6)
#   board_id:       板卡 ID
#   hw_ver:         硬件版本
#   node_guid:      节点 GUID
#   port 1:         端口信息
#     state:        端口状态 (PortDown/Active/Disabled)
#     sm_lid:       Subnet Manager LID
#     lid:          端口 LID
#     rate:         链路速率 (25Gb/s, 100Gb/s)
#     port_width:   端口宽度 (1x, 4x)
#     phys_state:   物理状态
```

### 3.2 ibstat

查看 IB 端口状态：

```bash
# 显示所有端口
$ ibstat

# 指定端口
$ ibstat mlx5_0 1

# 示例输出：
# CA 'mlx5_0'
#   Port 1:
#     State: Active
#     Physical State: LinkUp
#     Rate: 100
#     Base LID: 0x12
#     LMC: 0
#     SM LID: 0x01
#     SM Sl: 0
#     GID[00]: fe80000000000000:0x7cfe4503ff0014a
#     GID[01]: 192.168.1.10
```

### 3.3 ibdevinfo

查看 IB 设备系统信息：

```bash
# 查看所有 IB 设备
$ ibdevinfo

# 示例输出：
# CA mlx5_0:
#   Name: mlx5_0
#   Image: /lib/firmware/mlx5Nic.bin
#   FW version: 20.30.1000
#   Node GUID: 0x7cfe4503007d66
#   System image GUID: 0x7cfe4503fff7d66
```

### 3.4 ibswitches

查看连接的 IB 交换机：

```bash
# 发现网络中的交换机
$ ibswitches

# 示例输出：
# Switch  : 0x7cfe4503000a4c6 ports 36 "MF0;switch-xxx:SX6036(ATP)"
# Switch  : 0xb8ce:f60300a0c2e ports 18 "MF0;switch-yyy:SN2100(ATP)"
```

### 3.5 获取 GID 和 LID

```bash
# 查看 GID 表
$ ibv_global_gid
# 或
$ cat /sys/class/infiniband/mlx5_0/ports/1/gids

# 查看 LID 表
$ ibv_global_lid
# 或
$ cat /sys/class/infiniband/mlx5_0/ports/1/lids

# 查询特定 GID 的 LID
$ saquery --gids

# 查看 PKey
$ cat /sys/class/infiniband/mlx5_0/ports/1/pkeys
```

---

## 4. 网络诊断工具

### 4.1 ibdiagnet

全面的网络诊断工具：

```bash
# 基本用法：诊断整个子网
$ ibdiagnet

# 常用选项：
#   --pc           显示性能计数器
#   --get_all      获取所有诊断信息
#   --skip <check> 跳过特定检查
#   -o, --outdir   输出目录

# 示例：
# 1. 完整诊断
$ ibdiagnet --get_all -o /tmp/ibdiag

# 2. 只检查 PM 和链路
$ ibdiagnet --pm --links

# 3. 检查特定错误
$ ibdiagnet --errors

# 诊断输出文件：
#   /tmp/ibdiag/ibdiagnet.lst    - 发现的所有节点
#   /tmp/ibdiag/ibdiagnet.mlnx   - Mellanox 特定信息
#   /tmp/ibdiag/ibdiagnet.pm     - 性能计数器
```

### 4.2 ibnetdiscover

网络拓扑发现：

```bash
# 发现并显示网络拓扑
$ ibnetdiscover

# 保存拓扑
$ ibnetdiscover -o /tmp/topology.lst

# 查看特定交换机
$ ibnetdiscover -s <switch_guid>

# 示例输出：
# #
# # Topology file: generated on 2024-01-15 10:30:00
# #
# # Host: node1 ( guid 0x7cfe45030007d66 )
# # Switch: switch1 ( guid 0x7cfe4503000a4c6 )
# #
# [Node]Desc="HCA-1" Nodelineguid=0x7cfe45030007d66 Nodeportportguid=0x7cfe45030007d66
#    1 [1] -> SwitchPort 1
```

### 4.3 saquery

Subnet Administrator 查询工具：

```bash
# 查看所有节点
$ saquery -n

# 查看所有链路
$ saquery -l

# 查看路径
$ saquery -P

# 查看特定节点的端口
$ saquery -m <node_guid>

# 查询 CA 到 CA 的路径
$ saquery -c <src_guid> <dst_guid>

# 查看 GID 表
$ saquery --gids

# 查看 LID 表
$ saquery --lids
```

### 4.4 smpquery

Subnet Management 查询：

```bash
# 查询节点信息
$ smpquery nodeinfo <lid>

# 查询端口信息
$ smpquery portinfo <lid> [portnum]

# 查询交换机信息
$ smpquery switchinfo <lid>

# 示例：
$ smpquery portinfo 1 1  # 查询 LID=1 端口 1
```

### 4.5 常用诊断流程

```bash
#!/bin/bash
# rdma_diagnose.sh - RDMA 网络诊断脚本

echo "=== RDMA Network Diagnosis ==="

# 1. 检查设备
echo "[1] Device Status:"
ibv_devinfo 2>/dev/null || ibdevinfo

# 2. 检查端口
echo ""
echo "[2] Port Status:"
for DEV in $(ls /sys/class/infiniband/ 2>/dev/null); do
    echo "  Device: ${DEV}"
    ibstat ${DEV} 2>/dev/null | grep -E "State|Rate|GID"
done

# 3. 检查交换机
echo ""
echo "[3] Switches:"
ibswitches 2>/dev/null || echo "  No switches found or ibutils not available"

# 4. 检查错误
echo ""
echo "[4] Error Counters:"
for DEV in $(ls /sys/class/infiniband/ 2>/dev/null); do
    echo "  Device: ${DEV}"
    cat /sys/class/infiniband/${DEV}/ports/*/counters/*error* 2>/dev/null | head -5
done

# 5. 检查 PKey
echo ""
echo "[5] PKeys:"
cat /sys/class/infiniband/*/ports/*/pkeys 2>/dev/null

# 6. 网络拓扑
echo ""
echo "[6] Network Topology (partial):"
ibnetdiscover 2>/dev/null | head -30
```

---

## 5. 性能监控工具

### 5.1 perfmon

性能计数器监控：

```bash
# 查看可用的性能计数器
$ perfom -z

# 查看指定端口的计数器
$ perfom -d mlx5_0 -p 1

# 实时监控
$ perfom -d mlx5_0 -p 1 -i 1  # 每秒更新

# 输出格式：
#   PortXmitData     - 传输的数据量
#   PortRcvData      - 接收的数据量
#   PortXmitPackets  - 传输的数据包数
#   PortRcvPackets   - 接收的数据包数
#   PortXmitDiscard  - 传输丢弃
#   PortRcvErrors    - 接收错误
```

### 5.2 rdma stat

内核 RDMA 统计：

```bash
# 查看 RDMA 设备统计
$ rdma stat -d mlx5_0

# 查看特定 QP 统计
$ rdma stat -d mlx5_0 -q <qp_num>

# 查看链路状态
$ rdma link

# 示例输出：
# link nmlx5_0-1 state PORT_ACTIVE physical_state LINK_UP
#   [port1] port_link_layer: Ethernet
#   [port1] port_protocols: RoCE v2
```

### 5.3 ibtop

实时流量监控（需要 Mellanox OFED）：

```bash
# 启动交互式监控
$ ibtop

# 命令行模式
$ ibtop -d mlx5_0 -p 1

# 保存流量数据
$ ibtop -d mlx5_0 -f /tmp/ibtop.log
```

### 5.4 系统计数器

```bash
# 查看 /sys 下的 RDMA 统计
$ ls /sys/class/infiniband/*/ports/*/counters/

# 常用计数器：
$ cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_xmit_data
$ cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_rcv_data
$ cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_xmit_packets
$ cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_rcv_packets

# 错误计数
$ cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_rcv_errors
$ cat /sys/class/infiniband/mlx5_0/ports/1/counters/port_xmit_discards
```

---

## 6. 实用配置脚本

### 6.1 RDMA 环境检查脚本

```bash
#!/bin/bash
# check_rdma_env.sh - RDMA 环境检查

echo "=========================================="
echo "  RDMA Environment Check"
echo "=========================================="

# 检查内核模块
echo "[1] RDMA Modules:"
for mod in mlx5_ib mlx4_ib rdma_cm ib_ipoib ib_umad; do
    if lsmod | grep -q "^$mod"; then
        echo "  [OK] $mod loaded"
    else
        echo "  [WARN] $mod NOT loaded"
    fi
done

# 检查设备
echo ""
echo "[2] RDMA Devices:"
if ls /sys/class/infiniband/ &>/dev/null; then
    for DEV in /sys/class/infiniband/*; do
        DEVNAME=$(basename $DEV)
        STATE=$(cat $DEV/ports/1/state 2>/dev/null | awk '{print $2}')
        RATE=$(cat $DEV/ports/1/rate 2>/dev/null)
        echo "  - $DEVNAME: state=$STATE, rate=$RATE"
    done
else
    echo "  [ERROR] No RDMA devices found!"
fi

# 检查 IPoIB
echo ""
echo "[3] IPoIB Interfaces:"
for IB in /sys/class/net/*; do
    if [ -d $IB/device/infiniband ]; then
        NETNAME=$(basename $IB)
        IBPATH=$IB/device/infiniband
        DEV=$(ls $IBPATH)
        echo "  - $NETNAME -> $DEV"
    fi
done

# 检查 RoCE 配置
echo ""
echo "[4] RoCE/ECN Configuration:"
for DEV in /sys/class/infiniband/*; do
    DEVNAME=$(basename $DEV)
    echo "  Device: $DEVNAME"

    # ECN 配置
    if [ -f /sys/class/infiniband/$DEVNAME/ports/1/ecn/enable ]; then
        ECN=$(cat /sys/class/infiniband/$DEVNAME/ports/1/ecn/enable 2>/dev/null)
        echo "    ECN enabled: $ECN"
    fi

    # DCBX 状态
    if [ -f /sys/class/infiniband/$DEVNAME/ports/1/dcbx_mode ]; then
        DCBX=$(cat /sys/class/infiniband/$DEVNAME/ports/1/dcbx_mode 2>/dev/null)
        echo "    DCBX mode: $DCBX"
    fi
done

# 检查防火墙/安全策略
echo ""
echo "[5] Security/Firewall:"
if systemctl is-active --quiet firewalld 2>/dev/null; then
    echo "  [WARN] firewalld is active - may block RDMA"
elif systemctl is-active --quiet ufw 2>/dev/null; then
    echo "  [WARN] ufw is active - may block RDMA"
else
    echo "  [OK] No active firewall"
fi

echo ""
echo "=========================================="
```

### 6.2 RoCE 连通性测试脚本

```bash
#!/bin/bash
# roce_connectivity_test.sh - RoCE 连通性测试

SERVER_IP=${1:-192.168.1.10}
CLIENT_IP=${2:-192.168.1.11}
DEV=mlx5_0

echo "=== RoCE Connectivity Test ==="
echo "Server: $SERVER_IP, Client: $CLIENT_IP"

# 1. IB 设备检查
echo "[1] IB Device Check:"
ibv_devinfo -d ${DEV} | head -10

# 2. GID 检查
echo ""
echo "[2] GID Check:"
ibv_global_gid ${DEV} 0
ibv_global_gid ${DEV} 1

# 3. Ping-Pong 测试 (需要两台机器)
echo ""
echo "[3] RC Ping-Pong Test:"
echo "  Run on SERVER: ibv_rc_pingpong -g 0"
echo "  Run on CLIENT: ibv_rc_pingpong -g 0 $SERVER_IP"

# 4. 带宽测试
echo ""
echo "[4] Bandwidth Test:"
echo "  Run on SERVER: perftest -d ${DEV} -z -F ecn"
echo "  Run on CLIENT: perftest -d ${DEV} -z -F ecn $SERVER_IP"

# 5. UDP 测试
echo ""
echo "[5] UD Test:"
echo "  Run on SERVER: ibv_ud_pingpong -g 0"
echo "  Run on CLIENT: ibv_ud_pingpong -g 0 $SERVER_IP"
```

### 6.3 性能基准测试脚本

```bash
#!/bin/bash
# rdma_perf_bench.sh - RDMA 性能基准测试

DEV=${1:-mlx5_0}
REMOTE_IP=${2}
RESULTS_DIR=/tmp/rdma_perf_$(date +%Y%m%d_%H%M%S)

mkdir -p $RESULTS_DIR

echo "=== RDMA Performance Benchmark ==="
echo "Device: $DEV, Remote: $REMOTE_IP"
echo "Results: $RESULTS_DIR"

# 延迟测试
echo ""
echo "[1] Latency Test:"
for SIZE in 4 64 256 1024 4096 16384 65536 262144; do
    echo -n "  Size $SIZE: "
    if [ -z "$REMOTE_IP" ]; then
        # 本地测试（单侧）
        echo "SKIP (need remote IP)"
        break
    else
        # 远程测试
        perftest -d ${DEV} -s ${SIZE} -n 10000 -z 2>&1 | \
            grep -oP 'latency=\K[\d.]+'
    fi
done | tee $RESULTS_DIR/latency.tsv

# 带宽测试
echo ""
echo "[2] Bandwidth Test (RC):"
for SIZE in 64 256 1024 4096 16384 65536 262144 1048576; do
    echo -n "  Size $SIZE: "
    if [ -z "$REMOTE_IP" ]; then
        echo "SKIP (need remote IP)"
        break
    else
        perftest -d ${DEV} -c -s ${SIZE} -n 50000 -t 32 2>&1 | \
            grep -oP 'BW ave=\K[\d.]+'
    fi
done | tee $RESULTS_DIR/bandwidth_rc.tsv

# UD 带宽测试
echo ""
echo "[3] Bandwidth Test (UD):"
if [ -n "$REMOTE_IP" ]; then
    perftest -d ${DEV} -u -s 4096 -n 100000 -t 64 2>&1 | \
        tee $RESULTS_DIR/bandwidth_ud.txt
fi

echo ""
echo "Results saved to: $RESULTS_DIR"
```

---

## 7. 故障排除快速参考

### 7.1 常见问题与解决

| 问题                    | 原因            | 解决方案                    |
| ----------------------- | --------------- | --------------------------- |
| ibv_devinfo: no devices | RDMA 驱动未加载 | `modprobe mlx5_ib`          |
| Port state: DOWN        | 物理链路问题    | 检查光纤/SFP                |
| Ping-pong 失败          | GID/LID 错误    | 检查两端 GID 是否一致       |
| 带宽远低于预期          | PFC/ECN 未配置  | 检查 DCB 配置               |
| ECN 测试失败            | ECN 未启用      | `ethtool --set-ecn eth0 on` |
| 丢包严重                | 拥塞控制问题    | 检查 PFC 和 ECN 配置        |

### 7.2 命令速查表

```bash
# === 设备信息 ===
ibv_devinfo                    # Verbs 设备信息
ibstat                         # IB 端口状态
ibdevinfo                      # IB 设备系统信息
ibswitches                     # 交换机列表

# === 连通性测试 ===
ibv_rc_pingpong -g 0 <IP>     # RC ping-pong
ibv_ud_pingpong -g 0 <IP>     # UD ping-pong
rping -s / -c                  # RDMA socket 测试
ucmatose -S / -C               # UD/RC 测试

# === 性能测试 ===
perftest -d <DEV> -c -s <SZ>   # RC 带宽
perftest -d <DEV> -u -s <SZ>   # UD 带宽
perftest -d <DEV> -z -s <SZ>   # 延迟

# === 网络诊断 ===
ibdiagnet --get_all            # 完整诊断
ibnetdiscover                   # 拓扑发现
saquery -n                      # 节点列表
smpquery portinfo <LID>        # 端口信息

# === 性能监控 ===
perfom -d <DEV>                # 性能计数器
rdma stat                       # RDMA 统计
rdma link                       # 链路状态

# === 系统文件 ===
/sys/class/infiniband/*/ports/*/gids      # GID 表
/sys/class/infiniband/*/ports/*/pkeys     # PKey 表
/sys/class/infiniband/*/ports/*/rate     # 链路速率
/sys/class/infiniband/*/ports/*/state    # 端口状态
```

---

## 8. 总结

```
RDMA 工具要点：

  1. 性能测试
    - perftest: 最全面的带宽/延迟测试工具
    - ibv_rc/ud_pingpong: 基础连通性验证
    - rping/ucmatose: RDMA socket 风格测试

  2. 设备查询
    - ibv_devinfo: Verbs 层设备信息
    - ibstat: IB 端口状态和 GID
    - ibdevinfo: 系统级设备信息

  3. 网络诊断
    - ibdiagnet: 完整网络诊断
    - ibnetdiscover: 拓扑发现
    - saquery/smpquery: Subnet 管理查询

  4. 性能监控
    - perfom: 性能计数器
    - rdma stat: 内核统计
    - ibtop: 实时流量

  常用诊断流程：
    1. ibv_devinfo → 确认设备正常
    2. ibstat → 确认端口 Active
    3. ibv_rc_pingpong → 验证连通性
    4. perftest → 测试性能基准
    5. ibdiagnet → 完整网络诊断
```

---

> [!info] 下章预告
> 第二十章将介绍 **Latency 优化**——RDMA 延迟构成分析、微秒级优化技术、基准测试方法。

---

## 附录：perftest 完整选项参考

```
perftest 常用选项：

  模式选项：
    -c, --uc (未实现)     UC (Unreliable Connected)
    -z, --zerobytes      零字节测试
    -r, --recv_bytes     只接收模式
    -q, --send_bytes     只发送模式

  测试参数：
    -s, --size           消息大小
    -n, --iters          迭代次数
    -t, --tx-depth       发送队列深度
    -w, --cq-mod         CQ 调制 (每 N 个完成一次中断)
    -D, --duration       测试持续时间 (秒)
    -I, --inline         内联数据大小

  连接选项：
    -a, --addr           目标地址
    -b, --bidirectional  双向测试
    -F, --feature        特性 (ecn, pfc, etc.)

  输出选项：
    -v, --verbose        详细输出
    -f, --outputfilename 输出文件
    -O, --report-ops     每秒操作数
    -B, --dont_xmit      只接收模式
```
