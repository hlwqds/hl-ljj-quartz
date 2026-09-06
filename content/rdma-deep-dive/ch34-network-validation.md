---
title: "RDMA 第三十四章：RDMA 网络验证——链路测试、拥塞验证与一致性检查"
date: 2026-04-14
tags:
  [rdma, validation, network-test, perftest, congestion, consistency, link-check, roce, infiniband]
description: "详解 RDMA 网络验证方法：物理链路验证、端到端带宽测试、拥塞模拟、一致性检查、抖动与延迟验证、以及生产环境部署前的验收测试。"
---

> [!abstract] 核心要点
> RDMA 网络部署后，必须经过系统验证才能投入生产。本章介绍从物理链路到协议栈的完整验证体系：链路质量测试、端到端带宽/延迟基准、拥塞控制验证、一致性检查，以及从测试环境到生产环境的验收流程。

---

## 1. 验证体系概述

### 1.1 验证层次

```
RDMA 网络验证层次：

  ① 物理层验证
       └── 链路速率、线缆长度、光模块健康、误码率
       └── 工具：iblinkinfo、ethtool、ibportstate

  ② 协议层验证
       └── GID/PKEY/LID 配置、子网管理器、路由
       └── 工具：ibdiagnet、ibnetdiscover、saquery

  ③ 连通性验证
       └── 端到端 ping (RC/UD)、socket 连接
       └── 工具：ibv_rc_pingpong、rping

  ④ 性能验证
       └── 带宽、延迟、丢包率、重试率
       └── 工具：perftest、ib_send_lat/ib_write_lat

  ⑤ 拥塞验证
       └── PFC 触发、ECN 响应、队列深度
       └── 工具：perfmon、ibdiagnet -c

  ⑥ 一致性验证
       └── 多节点同速、多路径负载均衡、故障转移
       └── 工具：multi-node perftest、故障注入测试
```

### 1.2 验证时机

- **新集群部署后**：必须完成全量验证
- **网络变更后**（交换机升级、线缆更换）：验证受影响路径
- **故障修复后**：验证恢复正常
- **例行巡检**：周期性抽检关键指标

---

## 2. 物理层链路验证

### 2.1 链路速率与宽度

```bash
# 检查端口实际协商速率
$ ibstat mlx5_0 1
Port 1:
  State: Active
  Physical State: LinkUp
  Rate: 100Gb/s (EDR)
  Width: 4x

# 对比预期速率（不应低于设计值）
# 预期 100Gb/s，实际应为 100Gb/s
# 预期 4x，实际应为 4x（不能是 1x）

# 使用 ethtool 查看更详细的信息
$ ethtool mlx5_0
Settings for mlx5_0:
    Speed: 100000Mb/s
    Duplex: Full
    Port: InfiniBand
    ...
```

### 2.2 线缆与光模块验证

```bash
# Mellanox 线缆数字诊断接口 (DDM)
$ mstflint -d mlx5_0 query

# 读取光模块的温度、电压、偏置电流
# 任何异常读数（超出厂商规格）都需更换线缆

# 检查线缆长度是否合规（IB 标准有最大长度限制）
# Copper: 3m (QSFP28) / 5m (分支线)
# Fiber: 最高 300m (OM3) / 400m (OM4)

# 检查线缆是否损坏
$ ibportstate mlx5_0 1 query
  PortState:                Active
  LinkSpeedActive:          Speed=25Gbps Width=4x
  LinkSpeedSupported:       [EDR]
```

### 2.3 误码率测试

```bash
# 读取 Symbol Error Counter
$ perfquery -x 0x01 mlx5_0 1 | grep SymbolErrorCounter
SymbolErrorCounter: 0

# 误码率 = SymbolErrorCounter / (Time * LinkSpeed)
# 健康链路：SymbolErrorCounter = 0

# 长时间误码监测（建议 24 小时）
# 若出现 > 0 的 Symbol Error，可能是：
#   - 光模块老化
#   - 线缆质量差
#   - 连接器脏污
#   - 弯曲半径过大
```

---

## 3. 连通性验证

### 3.1 基础连通性测试

```bash
# 使用 ibv_rc_pingpong（需两端同时运行）

# 端 A (server)
$ ibv_rc_pingpong -g 2

# 端 B (client)
$ ibv_rc_pingpong -g 2 <A_gid>

# 若成功：显示 Round-trip latency 和 message rate
# 若失败：卡住或 timeout
```

### 3.2 rping 测试

`rping` 测试 RDMA-over-TCP (Sockets Direct) 连通性：

```bash
# 端 A 启动 server
$ rping -sv -a 192.168.1.10 -p 12345

# 端 B 连接
$ rping -cv -a 192.168.1.10 -p 12345

# 成功输出：
# rdma_connect success
# rdma_accept success
# data transfer completed successfully
```

### 3.3 多节点广播测试

```bash
# 验证多节点 UD 多播连通性
$ ibv_ud_pingpong -g 2

# 或使用 ibping 测试节点可达性（通过 SA 查询）
$ ibping -L 0x0001 -G <target_gid>
```

---

## 4. 性能基准测试

### 4.1 带宽测试

**perftest** 是 RDMA 性能测试的标准工具：

```bash
# RDMA Send/Recv 带宽（双向）
# 端 A
$ ib_send_bw -d mlx5_0 -F -R  # -R = 使用 RC
# 端 B
$ ib_send_bw -d mlx5_0 -F -R <A_gid>

# RDMA Write 带宽（单向）
# 端 A (sink)
$ ib_write_bw -d mlx5_0 -F
# 端 B (source)
$ ib_write_bw -d mlx5_0 -F <A_gid>

# RDMA Read 带宽（反向）
# 端 A
$ ib_read_bw -d mlx5_0 -F
# 端 B
$ ib_read_bw -d mlx5_0 -F <A_gid>
```

**关键参数：**

| 参数            | 含义                             | 推荐值       |
| --------------- | -------------------------------- | ------------ |
| `-F`            | 使用 inline data（减少内存访问） | 高带宽测试用 |
| `-s <size>`     | 消息大小                         | 2KB~4MB      |
| `-D <duration>` | 测试持续时间                     | 10~60s       |
| `-x <count>`    | 并发连接数                       | 多 QP 测试用 |

### 4.2 延迟测试

```bash
# RDMA Write 延迟（往返）
$ ib_write_lat -d mlx5_0 -F -s 4

# ib_send_lat（Send/Recv 往返延迟）
$ ib_send_lat -d mlx5_0 -F -s 4

# 典型延迟参考（100Gb/s EDR）：
#   RDMA Write:  ~1.5-2 us（端到端）
#   ib_send_lat: ~2-3 us
```

### 4.3 消息大小扫描

```bash
# 扫描不同消息大小的带宽变化
$ for size in 64 256 1K 4K 64K 1M; do
    echo "Size: $size"
    ib_write_bw -d mlx5_0 -s $size <dest_gid>
  done

# 预期结果：
#   < 256B: 带宽低（协议开销主导）
#   256B-4KB: 带宽快速上升
#   4KB-1MB: 带宽接近线速
#   > 1MB: 带宽稳定或略降（内存带宽限制）
```

### 4.4 多节点性能验证

```bash
# 在多节点上同时运行带宽测试
# 使用 MPI 或并行工具

# MPI-based allreduce 带宽测试
$ mpirun -n 4 ib_write_bw

# 全对全测试（all-to-all）
$ perftest -z -F -e  # bidirectional, exhaustive
```

---

## 5. 拥塞控制验证

### 5.1 PFC 触发测试

```bash
# 验证 PFC 是否正常工作
# 1. 在接收端监控 PFC 暂停帧
$ perfquery -x 0x35 mlx5_0 1 | grep PriorityXmitPause

# 2. 生成拥塞（高带宽流）
$ ib_send_bw -d mlx5_0 -F -t 16 <dest_gid>

# 3. 观察是否出现 Pause frames
# 若出现：PFC 正常
# 若不出现且有丢包：PFC 配置错误或链路不健康
```

### 5.2 ECN 标记测试

```bash
# RoCEv2 ECN 标记测试
# 1. 配置 ECN（参考第十八章）
$ sysctl -w net.ipv4.tcp_ecn=1

# 2. 运行拥塞测试
$ ib_send_bw -d mlx5_0 -F -t 16 <dest_gid>

# 3. 检查 ECN 标记计数
$ perfquery -x 0x51 mlx5_0 1 | grep ECNMark

# ECN 标记出现 = ECN 机制正常
```

### 5.3 拥塞压力测试

```bash
# 模拟多对一拥塞（incast）
# 8 个发送方向同一个目标节点同时发送
# 在交换机上监控队列深度和丢包

# 测试步骤：
# 1. 启动目标节点的 receive 测试
$ ib_write_bw -d mlx5_0 -F

# 2. 启动 8 个发送节点
for i in {1..8}; do
    ib_write_bw -d mlx5_0 -F <target_gid> &
done

# 3. 观察交换机 counter
# PortXmitDiscards 应该 = 0（无损网络）
# PriorityXmitPause 应该 > 0（PFC 正常触发）
```

---

## 6. 一致性检查

### 6.1 链路速率一致性

```bash
# 检查集群中所有节点的实际链路速率
# 应该与设计值一致（不降级）

$ for node in $(cat nodes.txt); do
    ssh $node "ibstat | grep Rate" &
  done

# 所有节点 Rate 应该相同（例如都是 100Gb/s EDR）
# 出现 25Gb/s（SDR）或 50Gb/s（HDR）说明链路有问题
```

### 6.2 GID/PKEY 一致性

```bash
# 检查所有节点的 GID 前缀是否一致
$ for node in $(cat nodes.txt); do
    ssh $node "ibv_devinfo | grep GID" &
  done

# 期望：所有节点 GID 在同一子网（相同前缀）
# 若出现不同 GID，前端通信无法建立

# 检查 PKEY 是否一致
$ for node in $(cat nodes.txt); do
    ssh $node "ibv_devinfo | grep PKEY" &
  done

# PKEY 必须匹配（默认 0xFFFF）
```

### 6.3 MTU 一致性

```bash
# 检查路径 MTU（所有节点和交换机）
$ ibnetdiscover | grep MTU

# 期望：所有链路 MTU 一致（通常 4096）
# 混合 MTU 可能导致路径验证失败

# RoCE 环境检查：
$ ip link show mlx5_0 | grep mtu
# MTU 应该 >= 4096（RoCEv2 需要更大 MTU）
```

### 6.4 子网管理器一致性

```bash
# 检查 SM 是否在所有交换机上运行（冗余 SM）
$ for sw in $(cat switches.txt); do
    ssh $sw "ibstat | grep SM"
  done

# 期望：所有交换机 SM 状态为 ACTIVE
# 只在部分交换机运行 SM 时，主备切换可能有问题

# SA 查询（确认 SM 路由正确）
$ saquery -g 2           # 查看路径
$ saquery -r <lid>       # 查看路由表
```

---

## 7. 验收测试流程

### 7.1 新集群验收

```bash
# RDMA 网络验收测试（建议 8 小时压力测试）

# Day 1: 基础验证（2 小时）
echo "=== Day 1: 基础验证 ==="
# 1. 链路质量（iblinkinfo）
# 2. 拓扑发现（ibnetdiscover）
# 3. 配置一致性（GID/PKEY/MTU）
# 4. 基础连通性（ibv_rc_pingpong）

# Day 2: 性能基准（4 小时）
echo "=== Day 2: 性能基准 ==="
# 1. 单向带宽（perftest）
# 2. 往返延迟（ib_write_lat）
# 3. 多节点 all-to-all
# 4. 长时间稳定性（24 小时 ib_send_bw）

# Day 3: 拥塞压测（2 小时）
echo "=== Day 3: 拥塞压测 ==="
# 1. PFC 触发测试
# 2. Incast 测试（8 对 1）
# 3. ECN 标记测试
```

### 7.2 关键验收指标

```
RDMA 网络验收标准：

  ┌─────────────────────────────────────────────────────────┐
  │  指标                 合格标准          优秀标准        │
  ├─────────────────────────────────────────────────────────┤
  │  链路速率             100% 设计值      100% 设计值      │
  │  Symbol Error         0                0                │
  │  单向带宽(2KB)        >= 90% 线速      >= 95% 线速      │
  │  单向带宽(4MB)        >= 95% 线速      >= 98% 线速      │
  │  RDMA Write 延迟       <= 3 us          <= 2 us         │
  │  丢包率               0                0                │
  │  VL15Dropped          0                0                │
  │  PFC 触发             拥塞时触发        拥塞时触发        │
  └─────────────────────────────────────────────────────────┘
```

### 7.3 回归测试

```bash
# 网络变更后的回归测试（简化版）
# 验证受影响路径，而非全量测试

# 1. 链路状态（快速检查）
ibstat | grep -E "State|Physical State"

# 2. 带宽（抽查 2-3 条路径）
ib_write_bw -d mlx5_0 <dest_gid>

# 3. 错误计数
perfquery -x 0x20 mlx5_0 1 | grep PortRcvErrors

# 4. PFC 触发（抽查）
# 在变更路径上运行拥塞测试
```

---

## 8. 自动化验证脚本

```bash
#!/bin/bash
# RDMA 网络验证脚本（完整版）

set -e

LOG_DIR="/var/log/rdma_validation"
mkdir -p $LOG_DIR
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== RDMA Network Validation ==="
echo "Start: $(date)"

# 1. 物理层检查
echo "[1/6] Checking link state..."
iblinkinfo > $LOG_DIR/link_$TIMESTAMP.log
if grep -q "LinkUp" iblinkinfo.log; then
    echo "  PASS: All links Up"
else
    echo "  FAIL: Some links Down"
fi

# 2. 错误计数检查
echo "[2/6] Checking error counters..."
perfquery -x 0x01 mlx5_0 1 | grep SymbolErrorCounter > $LOG_DIR/errors_$TIMESTAMP.log
if grep -q "SymbolErrorCounter: 0" $LOG_DIR/errors_$TIMESTAMP.log; then
    echo "  PASS: No symbol errors"
else
    echo "  WARN: Symbol errors detected"
fi

# 3. GID/PKEY 检查
echo "[3/6] Checking GID/PKEY..."
ibv_devinfo | grep -E "GID|PKEY" > $LOG_DIR/gidpkey_$TIMESTAMP.log

# 4. 连通性测试（需要 peer 节点）
echo "[4/6] Testing connectivity..."
ibv_rc_pingpong -g 2 > /dev/null 2>&1 && echo "  PASS: RC connectivity OK" || echo "  FAIL: RC connectivity"

# 5. 带宽测试
echo "[5/6] Testing bandwidth..."
ib_write_bw -d mlx5_0 -F -s 4096 > $LOG_DIR/bw_$TIMESTAMP.log 2>&1 || echo "  SKIP: No peer"

# 6. 拥塞测试（可选，需要额外节点）
echo "[6/6] Checking congestion metrics..."
perfquery -x 0x35 mlx5_0 1 > $LOG_DIR/congestion_$TIMESTAMP.log

echo "=== Validation Complete ==="
echo "Log: $LOG_DIR/validation_$TIMESTAMP.tar.gz"
```

---

## 9. 小结

- **物理层是基础**：链路速率、误码率、光模块健康，任何一项不达标都会导致上层问题
- **perftest 是性能验证的标准工具**：覆盖带宽、延迟、多节点、拥塞等场景
- **拥塞验证是 RoCE 特有的验证重点**：PFC 触发、ECN 标记、VL15Dropped 都是关键指标
- **一致性检查防止木桶效应**：集群中任何节点的配置不一致都会成为通信瓶颈
- **自动化脚本**是持续质量保证的必要手段，建议纳入 CI/CD 流程
