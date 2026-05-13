---
title: "RDMA 第三十二章：RDMA 故障诊断——诊断工具、错误码分析与排错流程"
date: 2026-04-14
tags: [rdma, debugging, troubleshooting, ibdiagnet, ibnetdiscover, error-code, rdma-core, diagnosis]
description: "详解 RDMA 故障诊断方法论：ibdiagnet、ibnetdiscover、ibv_err_ce、错误码体系、通信失败与 QP 错误排查流程。"
---

> [!abstract] 核心要点
> RDMA 故障诊断需要从物理层到协议层逐层排查。本章介绍 RDMA 诊断工具链（ibdiagnet、ibnetdiscover、ibv_err_ce）、常见错误码含义、QP 状态与 syndrome 分析、以及典型通信失败的排错流程。

---

## 1. 诊断工具链概述

### 1.1 工具层次

```
RDMA 诊断工具层次：

  ┌──────────────────────────────────────────┐
  │  应用层   rping / ucmatose / perftest    │  ← 连通性与性能测试
  ├──────────────────────────────────────────┤
  │  verbs 层  ibv_devinfo / ibv_err_ce      │  ← 设备与错误码查询
  ├──────────────────────────────────────────┤
  │  SM/SA 层  ibdiagnet / ibnetdiscover      │  ← 子网拓扑与配置验证
  ├──────────────────────────────────────────┤
  │  链路层   ethtool / ibportstate          │  ← 物理链路状态
  ├──────────────────────────────────────────┤
  │  硬件层   ibstat / iblinkinfo            │  ← 端口与光模块信息
  └──────────────────────────────────────────┘
```

### 1.2 快速诊断流程

```bash
# 1. 检查设备可见性
$ ibv_devinfo
    └── 确认 HCA 端口状态 UP

# 2. 检查物理链路
$ ibstat
    └── 确认 PortState: Active

# 3. 检查子网管理器
$ ibnetdiscover
    └── 确认所有交换机和终端节点连通

# 4. 运行诊断
$ sudo ibdiagnet
    └── 完整子网验证报告

# 5. 检查错误计数
$ ibv_err_ce <device>
    └── CQE 错误详情
```

---

## 2. 子网拓扑发现

### 2.1 ibnetdiscover

`ibnetdiscover` 扫描并显示 InfiniBand 或 RoCE 子网的拓扑结构：

```bash
# 基本扫描（需要 root）
$ sudo ibnetdiscover

# 稀疏输出（只显示终端节点）
$ sudo ibnetdiscover -s

# 外部端口（查看交换机下行端口）
$ sudo ibnetdiscover -e

# 输出示例（部分）
...
#
# topology: 2024-01-15 10:23:45
# Number of nodes discovered: 24
#
Switch   0x0011ff00000a2c3a [mlx5_0]
|
|  Port 1
|   └─ Node  0x0012ff00000b1c2a [compute-01]
|   └─ Node  0x0013ff00000c3d1a [compute-02]
|
|  Port 2
|   └─ Node  0x0014ff00000d4e2b [storage-01]
...
```

**关键信息解读：**
- 显示每个交换机的级联拓扑和下游节点
- 节点旁的 GUID 和名称（如果是已知节点）
- 端口连接关系帮助定位物理布线问题

### 2.2 拓扑验证

通过拓扑文件与实际布线对比：

```bash
# 保存拓扑快照（用于变更比对）
$ sudo ibnetdiscover > topology_$(date +%Y%m%d).log

# 比对两份拓扑（布线变更检测）
$ diff topology_baseline.log topology_new.log
```

---

## 3. 完整诊断：ibdiagnet

### 3.1 全面子网验证

`ibdiagnet` 是 RDMA 诊断的"一站式"工具，执行以下检查：

```bash
$ sudo ibdiagnet

# 完整输出包含：
# 1. 链路速度和宽度验证
# 2. 端口状态检查
# 3. PKEY 配置验证
# 4. GID/IPv6 检查
# 5. 子网管理器连接验证
# 6. 交换机和路由配置检查
# 7. 错误计数与阈值检测
# 8. 路径 MTU 验证
```

### 3.2 按模块运行

```bash
# 只运行链路检查（不扫描 SM）
$ sudo ibdiagnet -l

# 只运行性能检查（不验证错误）
$ sudo ibdiagnet -p

# 指定端口
$ sudo ibdiagnet --port 1

# 生成报告文件（ibdiagnet.log）
$ sudo ibdiagnet -o /tmp/diagnosis/
```

### 3.3 输出解析

```
ibdiagnet 输出结构：

  [WARN] - 非致命问题（如错误计数 > 0）
  [ERROR] - 配置错误（需干预）
  [FATAL] - 子网管理器缺失等严重问题

  生成报告：
  /tmp/diagnosis/
    ibdiagnet.log          # 完整报告
    ibdiagnet.errors       # 所有错误的概要
    ibdiagnet.lids         # LID 映射表
    ibdiagnet.pkeys        # PKEY 表
```

### 3.4 常见警告解读

```bash
# [WARN] Port X counter: symbol_error > threshold
# → 光模块或线缆物理问题（误码率高）

# [WARN] PKEY mismatch on port Y
# → 两个节点的 PKEY 子网 ID 不同，无法通信

# [WARN] SM not responding on port Z
# → 子网管理器连接失败，需要检查 SM 配置

# [ERROR] Port disabled due to excessive errors
# → 硬件保护机制触发，端口已被禁用
```

---

## 4. 错误码分析

### 4.1 CQE 错误码

当 RDMA 操作完成时，Completion Queue Entry (CQE) 中的 `status` 字段指示结果。正常为 `IBV_WC_SUCCESS`，错误有不同的状态码：

```c
// 常见 WC status（来自 ibverbs.h）
IBV_WC_SUCCESS              // 操作成功
IBV_WC_LOC_LEN_ERR          // 本地 length 错误（SG list 长度不匹配）
IBV_WC_LOC_QP_OP_ERR        // 本地 QP 状态错误（QP 未正确配置）
IBV_WC_LOC_EEC_OP_ERR       // 本地 EEC 错误
IBV_WC_WR_FLUSH_ERR         // 工作请求在 flush 状态时完成（对端 QP 被销毁）
IBV_WC_MW_BIND_ERR          // Memory Window 绑定错误
IBV_WC_BAD_RESP_ERR         // 错误响应（通常为协议错误）
IBV_WC_LOC_ACCESS_ERR       // 本地访问错误（权限不足）
IBV_WC_REM_INV_REQ_ERR      // 远端请求无效（R_KEY 失效等）
IBV_WC_REM_ACCESS_ERR       // 远端访问错误（权限不足）
IBV_WC_REM_OP_ERR           // 远端操作错误（操作不支持）
IBV_WC_RETRY_EXC_ERR        // 重试耗尽（丢包导致重试超时）
IBV_WC_RNR_RETRY_EXC_ERR    // RNR 重试耗尽（接收方无可用 WR）
IBV_WC_LOC_RDD_VIOL_ERR     // 本地 RDD 违规
IBV_WC_REM_INV_RD_REQ_ERR   // 远端 RD 请求无效
IBV_WC_ABORT_ERR            // 操作中止
IBV_WC_RESP_TIMEOUT_ERR     // 响应超时
IBV_WC_GENERAL_ERR          // 通用错误
```

### 4.2 ibv_err_ce 工具

`ibv_err_ce` 从 CQE 提取人类可读的错误描述：

```bash
# 查看指定设备的错误详情
$ sudo ibv_err_ce mlx5_0

# 示例输出：
# Device: mlx5_0
# last CQE error: 2024-01-15 14:23:01
#     status:     IBV_WC_RNR_RETRY_EXC_ERR
#     syndrome:   0x0041a2b3
#     QP:         0x12345
#     opcode:     IBV_WC_RECV
#     wr_id:      0xabcdef01
```

### 4.3 错误分类与对策

| 错误码 | 类别 | 常见原因 | 排错步骤 |
|--------|------|----------|----------|
| `WR_FLUSH_ERR` | 通信方 QP 销毁 | 对端进程崩溃/QP 重建 | 检查对端应用状态 |
| `RNR_RETRY_EXC_ERR` | 接收方无 WR | 本端 Receive Q 未准备 | 预 posting Receive WR |
| `REM_INV_REQ_ERR` | R_KEY 失效 | 内存区域被注销 | 检查 MR 生命周期 |
| `LOC_QP_OP_ERR` | QP 状态错误 | 未进入 RTS 状态 | 检查 QP state machine |
| `RETRY_EXC_ERR` | 重试耗尽 | 丢包/拥塞/链路故障 | 检查链路错误计数 |
| `BAD_RESP_ERR` | 协议错误 | 版本不匹配/格式错误 | 检查驱动和固件版本 |
| `MW_BIND_ERR` | MW 绑定错误 | 权限或地址无效 | 检查 bind 参数 |

---

## 5. QP 状态与通信排查

### 5.1 QP 状态机回顾

QP 有多种状态，通信失败往往与状态转换错误有关：

```
QP 状态机：

  RESET → INIT → RTR → RTS
    ↑        ↑        ↓
    └────────┴────────┘  (错误时)
              ↓
           ERR → SQE → RESET
```

- **RESET**：QP 刚创建，无法处理任何 Work Request
- **INIT**：已初始化，仍不能发送
- **RTR (Ready To Receive)**：已可接收，但尚不能发送
- **RTS (Ready To Send)**：完全就绪，可发送所有操作
- **ERR**：出现错误，不再处理新请求

### 5.2 排查连接建立失败

```bash
# 1. 检查两端 QP 状态
$ ibv_rc_pingpong <local_gid> <remote_gid>
# 若卡住，通常是：
#   - 网络不通（链路层问题）
#   - GID/PKEY 不匹配
#   - 防火墙/SM 过滤

# 2. 检查 GID 是否正确
$ ibv_devinfo | grep GID
# 确保两端 GID 在同一子网

# 3. 检查 PKEY
$ ibv_devinfo | grep PKEY
# 确保两端 PKEY 相同（默认 0xFFFF）

# 4. 检查 SM 是否在运行
$ sudo ibstat | grep SM
# PortState: Active, SM: ACTIVE

# 5. 检查 rping（更高级的连接测试）
$ rping -sv -a <remote_ip> -p 12345
```

### 5.3 RDMA Write/Read 失败

RDMA one-sided 操作依赖对端 QP 处于 RTS 状态且内存注册有效：

```bash
# 检查 remote_addr 和 rkey 是否正确传递
# 应用日志中确认 GID、QPN、rkey、remote_addr 正确交换

# 在对端检查 MR 是否仍然有效
$ ibv_rc_pingpong -g <gid>  # 使用 ibv_rc_pingpong 验证基本连通性

# 检查 RNR NAK 计数（接收方没有可用的 Receive WR）
$ ibv_devinfo -v | grep -i rnr
```

---

## 6. 链路与物理层排查

### 6.1 端口状态检查

```bash
# Mellanox 设备
$ ibstat mlx5_0 1
# Port 1: Active
# Physical State: LinkUp
# Rate: 100Gb/s (EDR)
# Width: 4x (quad)

# 更详细的链路属性
$ iblinkinfo | grep -A5 mlx5_0
```

### 6.2 链路错误计数

```bash
# 使用 ibmsh（if dual-rail）或直接读 counters
$ sudo ibv_err_ce mlx5_0 --all   # 错误计数

# 通过 perfmon 读取详细端口统计
$ perfquery -L 1 mlx5_0 1       # PortCounters: LinkQuality
# 关键指标：
#   SymbolErrorCounter      → 光模块物理问题
#   LinkErrorRecoveryCounter → 链路不稳定
#   PortRcvErrors           → 接收错误
#   PortRcvRemRouteErrors   → 路由错误
```

### 6.3 交换机端排查

```bash
# 查看交换机端口状态（Mellanox SN2700）
$ show interface ethernet 1/1

# 查看计数器
$ show counters ethernet 1/1

# 查看 PFC 状态
$ show dcb priority-flow-control

# 检查 ECN 配置
$ show dcb traffic-pool
```

---

## 7. 日志与调试信息

### 7.1 内核日志

```bash
# RDMA 内核子系统的错误日志
$ dmesg | grep -i 'rdma\|mlx5\|ib_'
[  123.456789] mlx5_0:mlx5_ib_query_device: alg 0x123 failed
[  123.789012] ib_mad[1234]: SM: Port 1 responding to missing SM

# 详细信息级别（调试模式）
$ echo "module mlx5_ib +p" > /sys/kernel/debug/dynamic_debug/control
```

### 7.2 rdma-core 日志

```bash
# 启用 verbs 日志
$ RDMA_VERBS_LOG=5 ./my_rdma_app

# 查看 CM 调试日志
$ RDMA_CM_DEBUG=1 ./my_rdma_app
```

### 7.3 WireShark RDMA 抓包

```bash
# 在具有镜像功能的交换机上抓取 IB 报文
# 使用 OmniPath 或 IB 专用抓包工具

# 或在 RoCE 环境中使用 tcpdump（抓取 UDP 4784 等）
$ tcpdump -i mlx5_0 -nn 'udp port 4791'  # RoCEv2
```

---

## 8. 排错流程总结

```
RDMA 排错流程图：

  ① 应用报错（rping 失败 / CQE 错误）
         ↓
  ② 检查物理层
         ├── ibstat → PortState = Active?
         └── iblinkinfo → Rate/Width 正确?
         ↓ 物理层正常
  ③ 检查子网层
         ├── ibnetdiscover → 拓扑发现?
         ├── ibdiagnet → 全面验证报告
         └── ibswitches → SM 运行中?
         ↓ 子网正常
  ④ 检查 GID/PKEY/LID 配置
         ├── 两端 GID 同一子网?
         └── 两端 PKEY 一致?
         ↓ 配置正常
  ⑤ 检查 QP 状态
         ├── QP 是否达到 RTS?
         └── 对端 QP 是否正常?
         ↓ QP 正常
  ⑥ 检查内存注册
         ├── MR 是否仍然有效?
         ├── rkey 是否正确?
         └── 权限是否足够?
         ↓ MR 正常
  ⑦ 深入错误码
         └── ibv_err_ce → 错误类型 → 针对性修复
```

---

## 9. 常用命令速查表

| 命令 | 用途 |
|------|------|
| `ibv_devinfo` | 查看本地设备信息、GID、QP 数量 |
| `ibstat` | 查看所有端口状态和 SM |
| `iblinkinfo` | 链路信息和错误计数 |
| `ibnetdiscover` | 发现子网拓扑 |
| `ibdiagnet` | 完整子网诊断 |
| `ibv_rc_pingpong` | RC 连通性测试 |
| `ibv_ud_pingpong` | UD 连通性测试 |
| `rping` | RDMA socket 连通性测试 |
| `perfquery` | 读取端口性能计数器 |
| `ibv_err_ce` | 解析 CQE 错误信息 |
| `ibaddr` | 查询 LID/GID 地址 |
| `smpquery` | 查询子网管理属性 |

---

## 10. 小结

- **诊断工具层次**：从物理层（ibstat/iblinkinfo）到子网层（ibdiagnet/ibnetdiscover）再到应用层（rping/perftest）
- **ibdiagnet** 是最全面的诊断工具，可一次性完成链路、配置、错误的全面验证
- **CQE 错误码** 是精确定位 RDMA 操作失败原因的关键
- **QP 状态机** 错误是 RDMA Write/Read 失败的首要原因
- **物理层链路质量**（误码率、光模块健康）是一切的上层基础