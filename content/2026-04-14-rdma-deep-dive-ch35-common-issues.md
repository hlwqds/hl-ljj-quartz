---
title: "RDMA 第三十五章：RDMA 常见问题——PKEY 错误、GID 问题、LID 冲突与解决方案"
date: 2026-04-14
tags: [rdma, common-issues, troubleshooting, PKEY, GID, LID, QP, error-resolution, roce, infiniband]
description: "详解 RDMA 常见问题的诊断与解决：PKEY 错误、GID 配置问题、LID 冲突、QP 状态异常、MR/MW 生命周期问题、拥塞与丢包、性能下降。"
---

> [!abstract] 核心要点
> 本章汇总 RDMA 实际部署中最高频的问题：通信失败、配置错误、性能异常。按问题现象分类，提供症状识别、原因定位、解决方案的完整路径，适合运维工程师快速查阅。

---

## 1. 连接建立失败

### 1.1 PKEY 不匹配

**症状**：`ibv_rc_pingpong` 卡住或超时，应用日志显示 `PKEY mismatch` 或 `QP creation failed`。

**原因**：两端节点的 PKEY 子网 ID 配置不一致。

**诊断**：

```bash
# 查看本端 PKEY
$ ibv_devinfo | grep PKEY
hca_id: mlx5_0
        pkey: 0xffff        # 默认 PKEY（0xFFFF）

# 交换机的 PKEY 配置（Mellanox）
$ show vlan

# 使用 ibdiagnet 检查所有节点的 PKEY 一致性
$ sudo ibdiagnet -p | grep -i pkey

# 远端 PKEY 查询（需要 SA access）
$ saquery -P <lid>
```

**解决**：

```bash
# 1. 确保所有节点使用相同的 PKEY（通常 0xFFFF）
# 在 opensm.conf 中配置默认 PKEY：
# default_mkey 0xFFFFFFFF
# default_pkey 0xFFFF

# 2. 对于多租户场景，需要正确配置 PKEY 子网分段
# opensm.conf:
# pkeys 0x0001, 0x0002  # 管理员分配的 PKEY

# 3. 应用层确保连接时使用正确的 PKEY index
# ibv_create_qp_attr.pkey_index 设置为正确的值
```

### 1.2 GID 配置问题

**症状**：RC/UD 连接建立失败，`invalid GID` 错误，或数据发送成功但接收不到。

**原因**：GID 配置错误（IPv6 地址配置错误、网段不匹配、版本不一致）。

**诊断**：

```bash
# 查看本端 GID
$ ibv_devinfo | grep GID
0:  fe80:0000:0000:0000:0012:3456:789a:bcde   <-- Link-local (RoCEv2 用)
1:  0000:0000:0000:0000:0000:ffff:192.168.1.10  <-- IPv4 mapped

# 确认 GID 类型（RoCEv1 vs RoCEv2）
# RoCEv1: GID 前缀 0xFF12:xxxx:xxxx
# RoCEv2: GID 前缀 0xFE80:xxxx:xxxx (link-local) 或自定义

# 常用诊断命令
$ ibaddr                                 # 显示 LID/GID
$ saquery -g                             # 显示路由 GID
```

**解决**：

```bash
# 1. RoCEv2 场景：确保 GID 是 link-local (fe80::) 或全局唯一 IPv6
# Mellanox 网卡默认自动生成：
#   ip -6 addr show mlx5_0
#   fe80::xxxx:xxxx:xxxx:xxxx/64

# 2. 检查两端是否在同一子网（IPv6 前缀相同）
# GID 不匹配 → 路由失败

# 3. 禁用错误的 GID（如果有多个 GID）
$ cma_roce_gid_index 2   # 指定使用 GID index 2

# 4. 配置静态 GID（不推荐，除非有特殊需求）
# ip -6 addr add <static-gid>/64 dev mlx5_0
```

### 1.3 LID 冲突

**症状**：`invalid LID` 错误，或拓扑中发现多个节点有相同 LID。

**原因**：
- 子网管理器配置问题导致 LID 分配冲突
- 手动分配 LID 与 SM 自动分配冲突
- 多子网场景中 LID 范围重叠

**诊断**：

```bash
# 查看本端 LID
$ ibaddr
LID: 0x0012

# 发现子网中所有 LID（检查冲突）
$ sudo ibnetdiscover | grep "LID"
Node  0x0012ff00000b1c2a compute-01 LID 0x0012
Node  0x0013ff00000c3d1a compute-02 LID 0x0013
Switch 0x0011ff00000a2c3a LID 0x0001

# 逐节点查询确认
$ ibswitches | grep LID

# 检查 SM 分配表
$ smpquery -G 0 ca  # 查询 CA 节点的 LID
```

**解决**：

```bash
# 1. 确保 SM 运行且配置正确
$ ibstat | grep SM
# SM: ACTIVE

# 2. 如果有手动 LID 配置，改为 SM 自动分配
# opensm.conf:
# lid_hibit 0          # 允许 SM 分配 LID

# 3. 多子网场景：确保各子网 LID 范围不重叠
# opensm.conf:
# subnet_prefix 0xFE80000000000000  # 不同子网用不同前缀

# 4. 重启 SM 重新分配 LID
$ sudo /etc/init.d/opensm restart
```

---

## 2. QP 状态与通信问题

### 2.1 QP 状态异常

**症状**：发送操作返回 `QP not in RTS state`，应用卡住或报错。

**原因**：QP 未正确转换到 RTS（Ready To Send）状态，或进入了 ERR 状态。

**诊断**：

```bash
# 查看 QP 状态（通过 ibv_query_qp）
# 代码中调用：
ibv_query_qp(qp, &attr, IBV_QP_STATE, &init_attr);
// attr.qp_state 应该为 IBV_QPS_RTS

# 使用 ibdiagnet 检查子网 QP 状态分布
$ sudo ibdiagnet -q | grep -i qp

# 通过 ibv_rc_pingpong 测试 QP 可用性
$ ibv_rc_pingpong -g 2 <dest_gid>
```

**解决**：

```bash
# 1. 确认 QP 创建后经过了正确的状态转换
# RESET → INIT → RTR → RTS

# 2. 检查每个转换的参数：
# INIT:  ibv_init_qp_attr(qp, &attr, IBV_QP_INIT)
# RTR:   ibv_init_qp_attr(qp, &attr, IBV_QP_RTR)
# RTS:   ibv_init_qp_attr(qp, &attr, IBV_QP_RTS)

# 3. 确认所有必需参数已设置：
# INIT: pkey_index, port_num, qp_access_flags
# RTR:  path_mtu, dest_qpnum, rq_psn, max_destination_rd_atomic
# RTS:  sq_psn, timeout, retry_cnt, rnr_retry

# 4. 若 QP 进入 ERR：重置 QP 并重新建立
ibv_modify_qp(qp, NULL, IBV_QP_STATE, IBV_QPS_RESET);
```

### 2.2 QP 创建失败

**症状**：`ibv_create_qp` 返回 NULL，errno 显示资源不足。

**原因**：QP 数量超限（超过 HCA 限制）或 PD 未正确分配。

**诊断**：

```bash
# 查看 HCA 的 QP 限制
$ ibv_devinfo
max_qp:        16384
max_qp_wr:     32768

# 当前已使用的 QP 数量
$ ibv_devinfo -v | grep "cur_qps"

# 排查 PD 限制
$ ibv_alloc_pd <device>
# 如果返回 NULL，可能是 PD 耗尽
```

**解决**：

```bash
# 1. 检查 QP 数量是否超限
# 应用层：确认没有泄漏的 QP 未正确销毁

# 2. 增加 HCA 的 max_qp（需要驱动/固件支持）
# mlx5 驱动参数：
$ echo 32768 > /sys/class/infiniband/mlx5_0/device/max_qp

# 3. 合理复用 QP（多连接共用 QP 或使用 SRQ）
# 参见第三十六章：Shared Receive Queue

# 4. 确认是否有遗留的 QP 未清理
$ ls /sys/class/infiniband/*/qp/
```

### 2.3 WR/CQ 错误

**症状**：`IBV_WC_LOC_QP_OP_ERR` 或 `IBV_WC_WR_FLUSH_ERR`。

**原因**：
- `LOC_QP_OP_ERR`：QP 状态不支持该操作（例如在 INIT 状态发送 RDMA Write）
- `WR_FLUSH_ERR`：对端 QP 被销毁，本端收到已 flush 的 WQE 完成

**诊断**：

```bash
# 检查 CQE 错误详情
$ sudo ibv_err_ce mlx5_0

# 查看本端和对端应用日志
# 对端 QP 销毁导致本端 WR 被 flush

# 检查 QP 是否进入 ERR 状态
```

**解决**：

```bash
# 1. 检查 QP 状态机转换是否正确
# RDMA Write 需要 QP 在 RTS 状态
# Send/Recv 操作也需要 QP 在 RTS 状态

# 2. 处理对端 QP 销毁的情况：
# 应用层：检测对端断开，重建 QP
# 清理残余 WQE：
ibv_poll_cq(cq, N, wc);  // poll out flushed WQE

# 3. 使用防泄漏模式：
# 确保每个 send/recv 都有对应的 post，即使对端崩溃
```

---

## 3. 内存注册问题

### 3.1 R_KEY 无效

**症状**：RDMA Write/Read 操作返回 `IBV_WC_REM_INV_REQ_ERR`，错误码 `0x82` (远端请求无效)。

**原因**：
- 对端的 Memory Region 被注销（mr dereg）
- 对端应用重启，MR 句柄失效
- 传递的 rkey 与本端注册的 key 不匹配

**诊断**：

```bash
# 检查本端 MR 状态
# MR 是否仍然注册？
ibv_query_mr(mr)  // 检查 lkey/rkey 是否有效

# 应用层日志：是否在 MR 注销后仍有 RDMA 操作？
# 典型的错误顺序：
# 1. 应用 A 注销 MR (dereg_mr)
# 2. 应用 B 仍尝试 RDMA Write 到该地址
# 3. → REMOTE INV REQ ERR
```

**解决**：

```bash
# 1. 确保 MR 生命周期覆盖所有 RDMA 操作
# MR 注销前：确认所有对端已完成操作（通过 fence 或同步）

# 2. 正确同步 MR 生命周期：
# - 使用 ibv_fence 等待远端操作完成
# - 使用事件机制通知对端 MR 变更

# 3. 定期更新 rkey（如果使用 slidable MR）
# 4. 应用层使用更高层的内存管理（避免手动 dereg）
```

### 3.2 Memory Window 问题

**症状**：`IBV_WC_MW_BIND_ERR`，Memory Window 绑定失败。

**原因**：
- MW bind 参数错误（地址对齐、权限）
- 绑定的 MR 已注销
- 尝试 bind 只读 MR 但权限包含写

**诊断**：

```bash
# 检查 MW bind 参数
# ibv_bind_mw() 的参数：
# - QP 状态？bind 操作需要 QP 在 INIT 或 RTS
# - 地址对齐？需要 4KB 对齐（部分实现）
# - 权限正确？IBV_ACCESS_REMOTE_WRITE 等

# 检查 MR 的权限
# mr->lkey / mr->rkey 的 access_flags
```

**解决**：

```bash
# 1. 检查 MW bind 的地址对齐
# 某些实现要求 4KB 对齐
addr = (uint64_t)buffer & ~4095;  // 对齐到 4KB

# 2. 确保绑定的 MR 仍然有效
# 不要在 MW 仍使用时注销 MR

# 3. 权限检查
# IBV_MW_TYPE bind 时，指定正确的 access_flags
# 如果只是读，使用 IBV_ACCESS_REMOTE_READ
# 如果要写，使用 IBV_ACCESS_REMOTE_WRITE

# 4. 使用 IBV_WR_ACCESS_MW 当作一个整体（更简单）
```

### 3.3 大内存区域注册失败

**症状**：`ibv_reg_mr` 返回 NULL，errno=ENOMEM。

**原因**：注册的大内存区域超出 HCA 可寻址范围，或预留的 GGA页表耗尽。

**诊断**：

```bash
# 查看 HCA 的内存限制
$ ibv_devinfo -v | grep -E "max_mr|max_mw|page_size"

# 检查系统内存
$ free -h

# 检查 hugepage 配置
$ cat /proc/meminfo | grep Huge

# 尝试注册较小的区域看是否成功
```

**解决**：

```bash
# 1. 确保系统有足够的 hugepage（2MB 或 1GB）
# echo 128 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 2. 使用 2MB 或 1GB hugepage 注册内存
# 对齐到 2MB 边界
void *buf = mmap(NULL, size, PROT_READ|PROT_WRITE,
                 MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB, -1, 0);

# 3. 增加 HCA 可用的 GGA 页表
# 通过驱动参数：
$ echo 100000 > /sys/class/infiniband/mlx5_0/device/gid_table_size

# 4. 分块注册大内存（多个 MR）
```

---

## 4. 性能异常问题

### 4.1 带宽远低于预期

**症状**：perftest 显示带宽只有理论值的 50% 甚至更低。

**原因**：链路速率降级、配置错误、CPU 瓶颈、拥塞。

**诊断**：

```bash
# 1. 检查实际链路速率
$ ibstat | grep Rate
# 若不是预期速率（如 100Gb/s），检查物理层

# 2. 检查 CPU 使用率（是否瓶颈在 CPU）
$ top -H
# 若 CPU 100%，说明应用处理能力不足

# 3. 检查拥塞指标
$ perfquery -x 0x35 mlx5_0 1 | grep PriorityXmitPause
# 若 > 0，说明有拥塞

# 4. 检查是否有较多重试
$ perfquery | grep -i retrans
```

**解决**：

```bash
# 1. 若链路速率降级：检查线缆和光模块（换线测试）
# 2. 若 CPU 瓶颈：
#    - 增加 CQ poll 的 batch size
#    - 使用多线程分担
#    - 绑核到 NUMA 节点
# 3. 若拥塞：配置 QoS 或增加带宽
# 4. 若重试多：检查链路误码率和 QP 参数（retry_cnt）
```

### 4.2 延迟波动大

**症状**：平均延迟正常，但 P99 延迟非常高（毫秒级）。

**原因**：中断风暴、锁竞争、内存分配阻塞、页错误。

**诊断**：

```bash
# 1. 检查中断分布
$ cat /proc/interrupts | grep -i mlx

# 2. 检查是否使用轮询模式（避免中断）
# 应用层配置：
struct ibv_device_attr attr;
ibv_query_device(dev, &attr);
if (!attr.kernel_cap_flags & IBV_DEVICE/poll_cq)
    // 不支持轮询

# 3. 检查内存分配路径
# 使用 mmap + MAP_HUGETLB 避免页错误
```

### 4.3 丢包率上升

**症状**：perftest 显示丢包或重试率高。

**原因**：PFC 配置错误、缓冲区满、链路错误、MTU 不一致。

**诊断**：

```bash
# 1. 检查错误计数
$ perfquery -x 0x20 mlx5_0 1 | grep PortRcvErrors

# 2. 检查 PFC 配置
$ dcbnl pfc show

# 3. 检查交换机端口缓冲区
$ show interfaces counters ethernet 1/1

# 4. 检查 MTU 一致性
$ ibnetdiscover | grep MTU
# 所有链路 MTU 应一致
```

**解决**：

```bash
# 1. 链路误码：更换线缆或光模块
# 2. PFC 配置问题：确保端到端 PFC 开启
#    ethtool -A mlx5_0 rx on tx on
# 3. MTU 不一致：统一所有节点的 MTU
#    ip link set mlx5_0 mtu 4096
# 4. 拥塞丢包：增加交换机缓冲区或启用 ECN
```

---

## 5. 驱动与固件问题

### 5.1 驱动加载失败

**症状**：`ibv_devinfo` 无法找到设备，或 `modprobe mlx5_ib` 失败。

**诊断**：

```bash
# 检查驱动是否加载
$ lsmod | grep mlx5

# 检查固件版本
$ mstflint -d mlx5_0 query

# 检查 PCI 设备是否被识别
$ lspci | grep -i mellanox
```

**解决**：

```bash
# 1. 重新加载驱动
$ modprobe -r mlx5_ib
$ modprobe mlx5_ib

# 2. 更新固件（通过 mstflint）
$ mstflint -d mlx5_0 burn -i /path/to/firmware.bin

# 3. 检查内核版本兼容性
# Mellanox OFED 需要特定内核版本
```

### 5.2 固件版本不兼容

**症状**：perftest 出现协议错误，ibdiagnet 报告 `firmware version mismatch`。

**诊断**：

```bash
# 查看固件版本
$ ibv_devinfo -v | grep fw_version
# 比较集群中所有节点的固件版本
```

**解决**：

```bash
# 1. 统一集群中所有节点的固件版本
# 2. 从厂商下载配套的固件版本
# 3. 升级步骤（Mellanox）：
#    a. 解压固件包
#    b. mstflint -d mlx5_0 burn -i fw.bin
#    c. reboot
# 4. 升级后重新验证
```

---

## 6. 云原生环境问题

### 6.1 RDMA CNI 故障

**症状**：Pod 无法获取 RDMA 设备，RDMA CNI 报错。

**诊断**：

```bash
# 检查 RDMA Device Plugin 运行状态
$ kubectl get pods -n rdma-resources

# 检查节点 RDMA 设备
$ kubectl describe node <node> | grep -A5 rdma

# 检查 CNI 配置
$ cat /etc/cni/net.d/rdma-cni.conf
```

**解决**：

```bash
# 1. 确保 RDMA device plugin 正确部署
# 参考第二十四章的部署步骤

# 2. 确认节点已加载 RDMA 驱动
# 3. 检查 Kubernetes RBAC 权限
# 4. 重建 CNI 配置
```

### 6.2 SR-IOV 虚拟化问题

**症状**：VF 无法创建，VM 内 RDMA 不可用。

**诊断**：

```bash
# 检查 PF 的 VF 数量配置
$ cat /sys/class/infiniband/mlx5_0/device/sriov_numvfs

# 检查 VF 是否绑定到 vfio-pci
$ lspci | grep -i virt
```

**解决**：

```bash
# 1. 启用 SR-IOV
$ echo 8 > /sys/class/infiniband/mlx5_0/device/sriov_numvfs

# 2. 配置 VF MAC/VLAN（RoCE 环境需要）
# 3. 将 VF 分配给 VM（通过 libvirt 或virt-manager）
```

---

## 7. 常见错误速查表

| 错误码 (hex) | WC Status | 含义 | 解决 |
|---|---|---|---|
| `0x01` | LOC_LEN_ERR | SG list 长度不匹配 | 检查 sge count 和 buffer size |
| `0x02` | LOC_QP_OP_ERR | QP 状态错误 | 检查 QP 是否在 RTS |
| `0x04` | LOC_EEC_OP_ERR | EEC 错误 | 重置 QP |
| `0x05` | WR_FLUSH_ERR | 对端 QP 销毁 | 重建 QP，处理 flush WC |
| `0x06` | MW_BIND_ERR | MW bind 错误 | 检查对齐和权限 |
| `0x0D` | BAD_RESP_ERR | 响应错误 | 检查协议版本/格式 |
| `0x10` | LOC_ACCESS_ERR | 本地权限错误 | 检查 MR 权限 |
| `0x11` | REM_INV_REQ_ERR | 远端 R_KEY 失效 | MR 已注销，更新 rkey |
| `0x12` | REM_ACCESS_ERR | 远端权限错误 | 检查 access_flags |
| `0x13` | REM_OP_ERR | 远端不支持的操作 | 检查操作类型 |
| `0x14` | RETRY_EXC_ERR | 重试耗尽 | 检查链路质量/拥塞 |
| `0x15` | RNR_RETRY_ERR | RNR 重试耗尽 | 检查对端 recv 队列 |
| `0x81` | GENERAL_ERR | 通用错误 | 查看具体日志 |

---

## 8. 小结

- **PKEY/GID/LID** 是 RDMA 通信的"地址系统"，任何不匹配都会导致连接失败
- **QP 状态机** 是 RDMA 操作的基础，错误的转换顺序是最常见的编程错误
- **MR/MW 生命周期** 需要与应用通信协议同步，禁止在远端仍使用时注销
- **性能问题** 从链路速率、物理误码、CPU 瓶颈、拥塞四个方向排查
- **驱动和固件** 是最容易被忽视的根因，保持集群版本一致是关键