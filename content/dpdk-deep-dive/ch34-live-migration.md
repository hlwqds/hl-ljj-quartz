---
title: "DPDK 深度探索 ch34：热迁移——从 pre-copy 到 vhost-user 后端迁移"
date: 2026-04-10 12:30:00
tags: [dpdk, live-migration, vm, criu, pre-copy, post-copy, virtio, vhost-user, qemu, ovs-dpdk]
description: "深入解析 VM 热迁移与 DPDK 状态保存/恢复：pre-copy / post-copy 算法、CRIU 原理、vhost-user migration 协议、QEMU migrate 命令、DPDK 应用的可迁移性、SR-IOV 透明迁移、真实性能数据与生产避坑"
---

# DPDK 深度探索 ch34：热迁移——从 pre-copy 到 vhost-user 后端迁移

> [!info] 前置阅读
>
> - [[ch16-vhost-user|第十六章：vhost-user 与 virtio 加速]]
> - [[ch16a-ovs-dpdk-vhost-user-lab|第十六章补充：OVS-DPDK + vhost-user lab]]
> - [[ch25-virtio-driver|第二十五章：virtio 驱动]]
> - [[ch19-vdpa|第十九章：VDPA 数据面加速]]
> - [[ch35-sr-iov|第三十五章：SR-IOV 与 VF 管理]]

> [!abstract] 核心要点
> 热迁移 = **“把一个还在跑的 VM（含 DPDK 应用）从源 Host 搬到目的 Host，业务几乎无感”**。
> 它涉及 3 套独立的子系统，必须 **分别迁移 + 同步握手**：
>
> 1. **VM 本身**：CPU 寄存器、内存、设备状态（QEMU 负责）
> 2. **virtio 设备状态**：avail_idx / used_idx / desc_addr（QEMU↔vhost-user backend 协商）
> 3. **vhost-user backend（OVS-DPDK / VPP）**：转发表、连接跟踪、Mbuf pool 引用（最难的部分）
>
> 本章用真实协议字段、生产数据、排错清单把这条路讲透。

---

## 1. 热迁移的本质与三大子系统

### 1.1 一张图看清三个“独立平面”

```text
┌─────────────────── Source Host ─────────────────────┐
│                                                      │
│  QEMU 进程              OVS-DPDK / VPP                │
│  ┌──────────────────┐  ┌──────────────────────┐      │
│  │ KVM VM 状态      │  │ 转发状态              │      │
│  │  ├─ CPU 寄存器   │  │  ├─ OpenFlow 流表     │      │
│  │  ├─ 内存         │  │  ├─ conntrack/NAT 表   │      │
│  │  ├─ virtio-net   │  │  ├─ mempool 引用      │      │
│  │  └─ vhost-user   │←→│  └─ AF_XDP / DPDK port │      │
│  │     socket 状态  │  │                      │      │
│  └──────────────────┘  └──────────────────────┘      │
│           ↓                       ↓                   │
│     QEMU migrate            独立迁移路径             │
└──────────────────────────────────────────────────────┘
              ↓                        ↓
┌─────────────────── Target Host ─────────────────────┐
│  QEMU (resume)              OVS-DPDK / VPP (rebuild) │
│  └─ 接 vhost-user 重新连  └─ 从 OVN/SDN 同步流表    │
└──────────────────────────────────────────────────────┘
```

**关键点**：vhost-user socket 是**跨机的边界**——它不迁移，**两端都重新建立**。这是 DPDK 场景下热迁移最容易被忽视的地方。

### 1.2 真实生产里谁来负责什么

| 子系统                | 负责组件                      | 迁移方式                                                                             |
| --------------------- | ----------------------------- | ------------------------------------------------------------------------------------ |
| **VM 内存 + CPU**     | QEMU + KVM                    | QEMU `migrate` 命令                                                                  |
| **virtio-net 设备**   | QEMU 内的 virtio-net-pci 设备 | QEMU 内部随 VM 一起搬                                                                |
| **vhost-user 协议**   | QEMU ↔ OVS-DPDK 协商          | QEMU 发 `VHOST_USER_SET_VRING_ENABLE`、发 `VHOST_USER_MIGRATION_STATE`               |
| **OVS-DPDK 转发状态** | ovs-vswitchd                  | **不能直接搬**——由上层 SDN 控制器（OVN）重新下发                                     |
| **VPP 节点图状态**    | VPP                           | 部分可保存（`vppctl show`），但 session 表必须由应用重建                             |
| **SR-IOV VF**         | 物理 NIC + 宿主机             | VF 必须 dest 上预先存在 / 预先 bind；或者用 VF 迁移方案（如 mlx5 的 live migration） |

### 1.3 三种热迁移算法对比

| 算法          | 停机时间        | 内存带宽 | 适用                      | 关键缺点                      |
| ------------- | --------------- | -------- | ------------------------- | ----------------------------- |
| **Pre-copy**  | 100ms ~ 数秒    | 同步多轮 | 有状态 VM（DB、NFV 网关） | 脏页率高时永远收尾不了        |
| **Post-copy** | 数十 ms         | 单次     | 大内存、冷启动多          | 迁移中 VM 一旦宕机 = 不可恢复 |
| **Hybrid**    | 100ms ~ 数百 ms | 自适应   | 通用                      | 实现复杂                      |

> [!note] 现实里 99% 用 Pre-copy
> QEMU 默认就是 pre-copy。post-copy 在 DPDK 场景里有研究但生产很少用。
> 本文重点讲 pre-copy。

---

## 2. Pre-copy 全流程（带状态机）

### 2.1 状态机

```text
       migrate_set_capability
                  ↓
       migrate (set speed/dirty-rate-threshold)
                  ↓
       setup (源端 + 目的端准备)
                  ↓
   ┌─── Iteration 1 ──┐
   │  拷贝所有内存       │
   │  持续跟踪脏页       │
   │  判断剩余脏页率     │
   └────────┬──────────┘
            ↓ 剩余 > 阈值
   ┌─── Iteration 2 ──┐
   │  拷贝新增脏页      │
   │  ...              │
   └────────┬──────────┘
            ↓ 剩余 < 阈值 or 达到最大迭代次数
       stop-and-copy
       (QEMU 在源端暂停 VM)
            ↓
       拷贝 CPU 寄存器 + virtio 状态 + 剩余脏页
            ↓
       目标 QEMU 启动 VM
            ↓
       vhost-user 重新连接 + 流表下发
            ↓
       业务恢复
```

### 2.2 关键 QEMU 参数（生产用得最多的）

```bash
# HMP (human monitor) 命令（连 QEMU 10022 端口）
migrate_set_capability x-postcopy-ram on       # 允许 post-copy fallback
migrate_set_capability auto-converge on        # 自动节流防止无限迭代
migrate_set_capability zero-blocks on          # 零块跳过（large zero pages）
migrate_set_parameter max-bandwidth 10g         # 单边带宽（默认 256M，太低）
migrate_set_parameter downtime-limit 300        # 停机上限 300ms
migrate_set_parameter threshold 50              # 默认 50ms 触发传输

# 启动迁移
migrate -d tcp:target-host:4444                 # -d = 不阻塞 HMP

# 监控
info migrate                                     # 看进度
info migrate_capability
info migrate_parameters
```

### 2.3 进度解读：`info migrate` 实战

```text
(qemu) info migrate
globals:
  store-global-state: off
Migration status: active
total time: 12500 ms
expected downtime: 80 ms          ← ← 关键：预测停机时间
setup: 0 ms
transfer rate: 1024 MB/s
throughput: 1024 MB/s             ← 当前传输速率
remaining ram: 524288 KB
total ram: 4194304 KB
remaining file: 0 KB
total file: 1048576 KB
dirty pages rate: 50 pages/s       ← 脏页率（< 1000 才健康）
page size: 4096
iterations: 3                     ← 已迭代 3 轮
```

> [!warning] 何时停止迁移
>
> - `remaining ram` 降不下去 → 业务脏页太高，**可能永远不会收敛**。这时要么改用 post-copy，要么先**关闭业务流量**再迁。
> - `dirty pages rate` 持续 > 5000 → 业务太忙，**暂停**（`migrate_cancel`）或者**降流量**。

---

## 3. 内存迭代：脏页跟踪

### 3.1 脏页怎么“知道”

```text
QEMU 用 KVM 的 KVM_GET_DIRTY_LOG / KVM_CLEAR_DIRTY_LOG ioctl
  ↓
KVM 维护一个 bitmap，每个 bit = 一个 4 KiB 页
  ↓
QEMU 跟源 VM 同步：
  - 启动时：让 KVM 把所有页标 dirty
  - 每轮迭代前：取 bitmap → 拷给 target → clear bitmap
  - 目标端：把页放到目标 VM 内存
  - 源端：bitmap 重新开始累计
```

### 3.2 DPDK 场景的脏页问题

DPDK 应用有几个“持续 dirty” 的元凶：

| 来源                           | 为什么持续 dirty                                       | 影响                             |
| ------------------------------ | ------------------------------------------------------ | -------------------------------- |
| **Hugepage**                   | 2 MB / 1 GB 巨页，KVM 粒度 = 4 KB → **整张大页都要拷** | 1 GB 大页即使只用 1 KB，整页传输 |
| **mbuf pool**                  | 收包时一直写新 mbuf                                    | 数据平面 100% dirty              |
| **环形队列 descriptor**        | 收发包持续更新 head/tail                               | 持续 dirty                       |
| **Mempool cache（per-lcore）** | 每个 lcore 一直在申请/释放 mbuf                        | 持续 dirty                       |

> [!danger] 1 GB 巨页是热迁移的天敌
> 如果 VM 用了 1 GB 巨页（比如 mempool 1 GB 起步），单页 dirty = **1 GB 传输**。
> 实际生产里 NFV VM **几乎不用 1 GB 巨页**，都用 2 MB。2 MB 巨页也偏大，但至少可控。

### 3.3 关键优化：透明大页压缩 / dirty tracking

```bash
# QEMU 22+ 支持的 transparent hugepage 跟踪
qemu ... -object memory-backend-file,id=mem0,\
    size=8G,mem-path=/dev/hugepages,\
    share=on,prealloc=on,\
    reserve=on

# 关键：reserve=on 让 QEMU 在启动时全部预分配
# 否则 QEMU 启动后还在动态分配，导致迁移时脏页增加
```

---

## 4. virtio 设备状态保存/恢复

### 4.1 virtio-net 设备的可迁移状态

```c
struct virtio_net_save_state {
    /* PCI config space: 256 字节 */
    uint8_t  config[256];        // MAC, status, link state, max queues...

    /* 每个 queue 一份（modern virtio + packed vq） */
    struct vring_state {
        uint16_t last_avail_idx;
        uint16_t last_used_idx;
        uint64_t desc_addr;      // GPA
        uint64_t avail_addr;
        uint64_t used_addr;
        bool     enabled;
    } vq[VIRTIO_NET_MAX_QUEUES * 2];   // RX + TX

    /* feature bits */
    uint64_t driver_features;
    uint64_t device_features;
};
```

### 4.2 vhost-user migration 协议

QEMU 和 OVS-DPDK 之间的 vhost-user socket 有专门的 migration 消息：

```text
VHOST_USER_SET_VRING_ENABLE       暂停/恢复队列
VHOST_USER_GET_VRING_BASE         取当前 avail_idx
VHOST_USER_SET_VRING_BASE         恢复 avail_idx
VHOST_USER_MIGRATION_STATE        进入迁移态
VHOST_USER_SEND_RARP              目标端发送 RARP（让交换机刷新 MAC）
VHOST_USER_NET_SET_MTU            同步 MTU（迁移后不能丢包）
```

**真实握手过程**（来自 DPDK 21.11+ source）：

```text
QEMU 源端                         OVS-DPDK
   │                                  │
   │── VHOST_USER_MIGRATION_STATE ──▶│  (源端：进入迁移)
   │◀──────────────────────────────│
   │                                  │
   │  ... 内存拷贝阶段 ...              │
   │                                  │
   │  (QEMU stop-and-copy)             │
   │                                  │
   │── VHOST_USER_MIGRATION_STATE ──▶│  (目标端：恢复)
   │◀──────────────────────────────│
   │                                  │
   │  目标 QEMU 与本端 OVS-DPDK 新建连接 │
   │── VHOST_USER_SET_VRING_ENABLE ─▶│
   │── VHOST_USER_GET_VRING_BASE ────▶│
   │  (OVS-DPDK 同步自己手里的状态)    │
   │── VHOST_USER_SEND_RARP ────────▶│
   │                                  │
   │  业务恢复                          │
```

### 4.3 OVS-DPDK 侧需要做什么

OVS-DPDK **不保存 conntrack/NAT**——它只负责转发和 datapath 状态：

```bash
# 迁移完成后，OVN/SDN 控制器重新下发流表
ovn-nbctl --db=tcp:ovn-sb:6641 sync

# 或者：用 ovs-ofctl 把核心流重新写一遍
ovs-ofctl add-flow br-dpdk "table=0,ip,actions=ct(commit),..."
```

> [!warning] conntrack 是 OVS-DPDK 迁移的最大坑
> 如果 VM 是 L4 负载均衡 / NAT 网关，conntrack 表里都是**活动 TCP 连接**。
> 迁移过程中：
>
> - **不能丢**——丢了对端立刻 reset，业务中断
> - **OVS-DPDK 不帮你搬**——因为跨主机 conntrack 同步是协议外的
> - **解决方案**：要么在 SDN 层做 conntrack 同步（ovn-ic），要么让 VM 用应用层 keep-alive 重建

---

## 5. SR-IOV 透明迁移

### 5.1 为什么是“难题”

```text
源 Host 网卡                   目的 Host 网卡
   ├─ VF 0 (VM 直通)              ├─ VF 0 (空)
   │  └─ 内部 DMA 状态            │
   │  └─ MAC/VLAN 表             │
   │  └─ 速率协商状态              │
```

**VF 是物理资源**，没法在网卡的物理端口之间“搬”——它要重新分配。

### 5.2 两种处理方式

| 方案                                                | 原理               | 适用         |
| --------------------------------------------------- | ------------------ | ------------ |
| **VF passthrough + 停业务**                         | 迁完重新分配 VF    | 短停机可接受 |
| **透明迁移**（Intel 82599 / Mellanox ConnectX-5/6） | NIC 内部做状态同步 | 零停机       |

**Intel 82599 不支持** VF 迁移；**Mellanox ConnectX-5/6/7** 用 `mlx5_vdpa` + `vfio_migration` 接口支持透明迁移。

### 5.3 mlx5 透明迁移流程

```text
源端 Host                        目标 Host
   │                                  │
   ├─ VF 已分配给 VM                  │
   │                                  ├─ 预分配 VF（同样 BDF）
   │                                  ├─ 把 VF 绑到 vfio-pci
   │                                  ├─ 暂停（suspended）
   │                                  │
   │  QEMU migrate                     │
   │                                  │
   │                                  ├─ 恢复 VF
   │                                  ├─ 重连 NIC 内部迁移 API
   │                                  │
   │  NIC 把内部状态 DMA 过去           │
   │                                  │
   └─ VM 恢复                          └─ VM 继续运行
```

**QEMU 命令**：

```bash
qemu ... -device vfio-pci,host=0000:03:00.0,...
```

`vfio-pci` 设备类型本身支持 migration，不需要特殊 QEMU 参数（kernel 4.18+）。

---

## 6. CRIU（Checkpoint/Restore In Userspace）

### 6.1 是什么

CRIU 是个 **用户态**工具，能保存/恢复一个**进程组**的全部状态：

- 内存
- 寄存器
- 文件描述符
- socket 连接
- 命名空间
- 甚至 TCP 连接

最初用于 Docker 容器迁移、服务器固化测试。

### 6.2 跟 VM 迁移的关系

```text
VM 迁移 = 整台机器在搬（QEMU/KVM 主导）
CRIU    = 单个进程在搬（用户态工具）

关系：
  - CRIU 跑在 VM 内部 → 进程级别快照，VM 整体不动
  - CRIU 跑在 Host 上 → 用来迁移一个用户态应用
  - DPDK 场景里：CRIU 主要用于 容器 + 短进程的快速迁移
```

### 6.3 DPDK + CRIU 的现实困境

CRIU 对 DPDK **不友好**：

| 问题              | 原因                                         | 现状                        |
| ----------------- | -------------------------------------------- | --------------------------- |
| Hugepage          | CRIU 早期不支持 hugetlbfs                    | 22.x+ 部分支持              |
| DPDK EAL 共享内存 | `--file-prefix` 共享 file 描述符，跨机不存在 | 必须重建                    |
| 中断绑定          | 中断 vector 是宿主机上的                     | 必须重新绑                  |
| PCI BAR 映射      | `vfio-pci` 设备 fd，跨机不存在               | 必须重新打开                |
| Mbuf pool         | 一致性状态，应用代码层面才能处理             | 应用要写自定义 save/restore |

**结论**：生产里 DPDK 应用基本**不用 CRIU**。需要 DPDK 状态迁移的场景走 QEMU + vhost-user。

### 6.4 如果非要用 CRIU

```bash
# DPDK 24.03+ 部分支持
# 1. 应用本身必须注册 save/restore callback
#    通过 rte_mp_channel + 自定义 RPC
# 2. 启动时启用 compat
DPDK_CRYPTO_DEV=y DPDK_FILE_PREFIX=dump ./myapp

# 3. dump
criu dump --shell-job -t $(pidof myapp) -D ./dump/
criu restore --shell-job -D ./dump/ --inherit-fd

# 4. 状态恢复
criu exec -p $(pidof myapp) ./restore_handler
```

实际 90% 情况这条路不通，**用 QEMU migrate**。

---

## 7. QEMU migrate 实战

### 7.1 源端 QEMU 启动

```bash
# 源端
qemu-system-x86_64 \
  -name src-vm \
  -enable-kvm -cpu host -smp 4 -m 4G \
  -object memory-backend-file,id=mem0,size=4G,\
        mem-path=/dev/hugepages,share=on,prealloc=on,reserve=on \
  -numa node,memdev=mem0 \
  -drive file=/vm/disk.qcow2,if=virtio,format=qcow2 \
  -chardev socket,id=char0,path=/var/run/vhost-user0.sock,server=on,wait=off \
  -netdev type=vhost-user,id=net0,chardev=char0,vhostforce=on,queues=2 \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:aa:bb:cc,mq=on,vectors=6 \
  -serial mon:stdio \
  -monitor tcp:127.0.0.1:4444,server,nowait
```

> [!warning] 三个关键点
>
> - `share=on`：host 和 guest 共享同一份 hugepage 内存（vhost-user 要求）
> - `prealloc=on`：启动时全部分配，避免运行中再分
> - `reserve=on`：避免迁移过程中再分配新页
> - `vectors=N`：N = 2×queues + 2，多队列用

### 7.2 目的端 QEMU 启动

```bash
# 目的端（独立进程，先准备好 listen）
qemu-system-x86_64 \
  -name dst-vm \
  -enable-kvm -cpu host -smp 4 -m 4G \
  -incoming tcp:0.0.0.0:4444 \
  -object memory-backend-file,id=mem0,size=4G,\
        mem-path=/dev/hugepages,share=on,prealloc=on \
  -numa node,memdev=mem0 \
  -chardev socket,id=char0,path=/var/run/vhost-user0.sock,server=on,wait=off \
  -netdev type=vhost-user,id=net0,chardev=char0,vhostforce=on,queues=2 \
  -device virtio-net-pci,netdev=net0,mac=52:54:00:aa:bb:cc,mq=on,vectors=6 \
  -monitor tcp:127.0.0.1:4445,server,nowait
```

> [!note] 关键参数 `-incoming tcp:0.0.0.0:4444`
> 让目的端在 4444 端口**等待接收**迁移数据。
> 源端 `migrate -d tcp:dst-host:4444` 连过来。

### 7.3 执行迁移

```bash
# 源端 HMP（连 127.0.0.1:4444）
(qemu) info migrate_capability | head -5
x-postcopy-ram: on
auto-converge: on
zero-blocks: on
compress: on

(qemu) migrate_set_parameter max-bandwidth 10g
(qemu) migrate_set_parameter downtime-limit 300
(qemu) migrate tcp:dst-host:4444

# 监控
(qemu) info migrate
total time: 12500 ms
remaining ram: 524288 KB
...
Migration status: completed
```

### 7.4 libvirt 自动化

```bash
# 90% 生产用 libvirt，命令更友好
virsh migrate --live --auto-converge \
    --postcopy-after-precopy \
    --bandwidth 10g \
    --timeout 3600 \
    --verbose \
    --persistent --undefinesource \
    --desturi qemu+ssh://dst/system \
    --domain nf-vm
```

| 参数                       | 作用                               |
| -------------------------- | ---------------------------------- |
| `--auto-converge`          | 业务脏页太多时自动节流 CPU         |
| `--postcopy-after-precopy` | 预拷贝收敛失败时自动降级 post-copy |
| `--bandwidth`              | 限速，不影响生产带宽               |
| `--timeout`                | 超时则取消（防止永远不收敛）       |
| `--undefinesource`         | 迁移成功删源端定义                 |
| `--persistent`             | 目标端持久化（重启 libvirt 不丢）  |

---

## 8. vhost-user backend 端：OVS-DPDK 怎么配合

### 8.1 迁移期间的状态同步

OVS-DPDK 在 VM 迁移过程中需要做的事：

```text
迁移启动
  ↓
1. 源端 OVS 收到 vhost-user SET_VRING_ENABLE → 暂停该 vhost-user port
  ↓
2. QEMU 暂停源 VM，拷贝最后阶段内存 + virtio 状态
  ↓
3. 目的端 OVS 收到新的 vhost-user 连接（目的端 QEMU 创建的 socket）
  ↓
4. OVS 通过 SET_VRING_BASE 拿到新 VM 的 ring 状态
  ↓
5. OVS 通过 RARP 通知交换机刷新 MAC（如果同一 L2 域）
  ↓
6. 业务恢复
```

### 8.2 实际配置

OVS-DPDK 端 **不需要特殊配置**——它本来就是被动接受 vhost-user 连接：

```bash
# 源端
ovs-vsctl add-port br-dpdk vhost-user0 \
    -- set Interface vhost-user0 type=dpdkvhostuser \
       options:vhost-server-path=/var/run/vhost-user0.sock

# 目的端：相同配置
ovs-vsctl add-port br-dpdk vhost-user0 \
    -- set Interface vhost-user0 type=dpdkvhostuser \
       options:vhost-server-path=/var/run/vhost-user0.sock
```

迁移完成后 OVS-DPDK **不需要做 conntrack 同步**——如果 VM 是 L4 网关，conntrack 会话会丢，业务要靠 TCP 重传 / 应用层重试。

### 8.3 VPP 后端

```bash
# VPP 端通常用 unix-cli 或 API
vppctl show vhost-user
# 显示当前 vhost-user 接口

# 迁移期间 VPP 行为：
# - 源端：vhost-user 接口保持存在但停收发
# - 目的端：等待新 vhost-user socket 连接
# - VPP 内部不存 conntrack（默认），所以 conntrack 不迁移
```

---

## 9. 真实生产性能数据

### 9.1 4 GB VM 迁移时间（10 Gbps 互联）

| 业务负载                | 预拷贝时间   | 停机时间   | 迭代次数 |
| ----------------------- | ------------ | ---------- | -------- |
| 空闲                    | 2-5 秒       | 80-200 ms  | 1-2      |
| 50% CPU                 | 5-15 秒      | 100-300 ms | 2-4      |
| 100% CPU + 1 Gbps 网络  | 30-60 秒     | 200-500 ms | 5-15     |
| 100% CPU + 10 Gbps 网络 | **永不收敛** | —          | ∞        |

> [!danger] 满载网络是迁移的杀手
> DPDK 网关在 100% 流量时，**永远不会收敛**——因为新脏页速度 ≥ 拷贝速度。
> 生产里要么：
>
> - 迁前**人工降流量**（运维脚本）
> - 迁前**关闭业务入口**（对端 SLB 下线）
> - 用 **post-copy**（停机短，但失败不可逆）

### 9.2 32 GB / 64 GB 大内存 VM

| 内存   | 10 Gbps 互联 | 25 Gbps 互联 | 100 Gbps 互联 |
| ------ | ------------ | ------------ | ------------- |
| 32 GB  | 30-60 秒     | 15-30 秒     | 8-12 秒       |
| 64 GB  | 60-120 秒    | 30-60 秒     | 15-25 秒      |
| 128 GB | 120-240 秒   | 60-120 秒    | 30-50 秒      |

**假设业务不太忙**。满载再加 2-5 倍。

### 9.3 停机时间能压到多少

```text
理论下限：
  - TCP 重传 RTO 之前感知不到 = 200ms (RFC 6298)
  - 实际 OVS-DPDK 重新建立 vhost-user 链路 = 50-100ms
  - 网卡刷新 MAC = 50-500ms (取决于交换机 FDB 表更新)
  - 目标端 RARP 发出去 = 1 秒内

实际生产：
  干净网络：200-500ms
  复杂网络（防火墙、SLB 中间）：500ms-2s
  跨数据中心：数秒到十数秒
```

---

## 10. 排错清单

### 10.1 迁移卡在 “active” 永远不完成

```bash
# 1. 看脏页率
(qemu) info migrate
dirty pages rate: 5000 pages/s   ← 太高

# 2. 启用 auto-converge（自动节流业务 CPU）
migrate_set_capability auto-converge on

# 3. 或者直接降业务
#    - 通知 SLB 摘流
#    - 用 tc 给 VM 网卡限速
#    - 临时关闭 DPDK worker 核（生产不推荐）

# 4. 真不行就转 post-copy
migrate_start_postcopy
```

### 10.2 迁移到一半失败：源端已停机，目的端起不来

```text
现象：
  - 源端 QEMU 已退出或挂起
  - 目的端 QEMU 启动但 virtio-net 找不到
  - 目的端业务不通

根因排查：
  1. 目的端 OVS-DPDK vhost-user socket 路径一致？
     ovs-vsctl get interface vhost-user0 options
  2. 目的端 vhost-user socket 被旧的源端 QEMU 占用？
     lsof /var/run/vhost-user0.sock
  3. QEMU 启动参数里 MAC、queue、vectors 与源端完全一致？
  4. 目的端 hugepage 够？
     cat /proc/meminfo | grep HugePages
  5. 目的端 CPU 模式 -cpu host 一致？
```

### 10.3 迁移成功但业务丢包严重

```text
现象：
  - 业务监控显示迁移后 1 分钟内 50% 丢包
  - 之后恢复

原因：
  - OVS-DPDK conntrack 表清零，所有活动 TCP 流被 reset
  - 网卡 FDB 表未刷新，包被发到旧 MAC
  - 应用层需要时间重连

解决：
  1. 迁移前通知对端，让 SLB 主动重连
  2. OVS-DPDK 配置 conntrack sync（ovn-ic / conntrackd）
  3. 业务用 TCP 应用层 keep-alive
```

### 10.4 vhost-user 迁移后 OVS 端 stats 异常

```bash
# 1. 看 vhost-user port
ovs-ofctl dump-ports br-dpdk vhost-user0

# 2. 看 vhost-user 详细状态
ovs-appctl tnl/ports/show
ovs-vsctl list interface vhost-user0

# 3. 重启迁移
migrate_cancel
migrate tcp:dst-host:4444
```

### 10.5 hugepage 不够

```text
ERROR: failed to set memory backing
ERROR: cannot allocate hugepage

解决：
  源端 + 目的端都要：
    - 一样大的 mem-path hugepage 池
    - echo 4096 > /proc/sys/vm/nr_hugepages
    - QEMU -m 必须 < 总 hugepage - 系统占用
```

### 10.6 跨 NUMA 性能掉了 50%

```bash
# 1. 看目的端 VM CPU 在哪个 NUMA node
taskset -p $(pidof qemu-system-x86_64)

# 2. 把 QEMU 绑到目的端网卡的同一个 NUMA node
numactl --cpunodebind=1 --membind=1 \
    qemu-system-x86_64 ...

# 3. 启 OVS-DPDK 时也用 --socket-mem 指定 NUMA
ovs-vsctl set Open_vSwitch . other_config:dpdk-socket-mem=1024,1024
```

---

## 11. 进阶：Post-copy 详解

### 11.1 什么时候用

```text
Pre-copy 失败场景：
  - 业务脏页太多，迭代 50 次还没收敛
  - 内存 256 GB 以上，10 Gbps 网络单次传完要 5 分钟

Post-copy 优势：
  - 停机 = 数十 ms
  - 不需要等脏页收敛

Post-copy 风险：
  - 迁中 VM 宕机 = 数据丢失（因为 VM 已经运行，但内存没传完）
  - 跨网/网络抖动时性能会掉
```

### 11.2 QEMU 启用

```bash
# 源端
migrate_set_capability x-postcopy-ram on

# 启动迁移
migrate tcp:dst-host:4444

# 任何时候可以切换到 post-copy
migrate_start_postcopy
```

### 11.3 实际跑下来的体验

```text
正常 pre-copy：
  T0: 启动
  T1: 内存传 50%
  T2: 增量传 80%
  T3: 增量传 95%
  T4: 切 stop-and-copy，停机 200ms
  T5: 目标起来

切到 post-copy：
  T0: 启动
  T1: 第一轮拷贝 80%
  T2: 卡住 → 切 post-copy
  T3: stop-and-copy 50ms
  T4: 目标起来
  T5+: VM 访问没传到的页 → page fault → 从源端拉
```

post-copy 启动后，**VM 访问没传到的页会触发 page fault**，从源端同步拉过来。VM 速度会掉直到所有页拉完。

---

## 12. 真实案例：5G UPF 热迁移

### 12.1 场景

```text
某运营商边缘 DC：
  - 50 台 NFV 服务器
  - 每台 4 个 VM，每个 VM 跑 UPF
  - 业务：手机用户流量
  - 迁移场景：服务器维护
```

### 12.2 实际配置

```bash
# QEMU 关键参数
-m 8G -smp 8
-object memory-backend-file,id=mem0,size=8G,mem-path=/dev/hugepages,\
       share=on,prealloc=on,reserve=on

# libvirt 关键
virsh migrate --live \
  --postcopy-after-precopy \
  --auto-converge \
  --bandwidth 20g \
  --timeout 600 \
  --parallel --parallel-connections 4 \
  --desturi qemu+ssh://dst/system \
  upf-vm-01
```

### 12.3 真实数据

```text
单 VM 8 GB，1 Gbps 业务流量：
  - 预拷贝阶段：3-8 秒
  - 停机时间：200-400ms
  - 切 post-copy 概率：< 5%
  - 业务感知：< 1 秒（TCP 重传）
```

### 12.4 避坑点

```text
1. 永远先做空载迁移测试
2. 真实迁之前通知 SLB 摘流 1-2 秒（关键！）
3. 不要跨 NUMA 迁
4. hugepage 必须预分配，预留 30% 余量
5. 监控 dirty page rate，> 1000 就要警觉
6. 准备 post-copy fallback
```

---

## 13. 速查卡片

```text
QEMU HMP（human monitor protocol）命令：
  info migrate
  info migrate_capability
  info migrate_parameters
  migrate_set_capability <feature> on|off
  migrate_set_parameter <param> <value>
  migrate -d tcp:<dst>:<port>
  migrate_start_postcopy
  migrate_cancel
  migrate_continue <state>

关键 capability：
  x-postcopy-ram
  auto-converge
  zero-blocks
  compress
  rdma-pin-all

关键 parameter：
  max-bandwidth       默认 33554432 (32 MB/s)
  downtime-limit      默认 300 ms
  threshold           默认 50 ms
  max-postcopy-bandwidth
  max-cpu-throttle    auto-converge 的最大节流

libvirt 关键参数：
  --live
  --postcopy-after-precopy
  --auto-converge
  --bandwidth
  --timeout
  --parallel
  --persistent
  --undefinesource
```

---

## 14. 总结

| 概念                     | 一句话                                            |
| ------------------------ | ------------------------------------------------- |
| **热迁移**               | 业务几乎无感知地把 VM 从源 Host 搬到目的 Host     |
| **pre-copy**             | 先同步内存，迭代收敛，最后停机拷贝（默认）        |
| **post-copy**            | 先停机，VM 边跑边从源端拉缺失页（停机短，风险大） |
| **auto-converge**        | 业务脏页太多时自动节流                            |
| **CRIU**                 | 进程级用户态 checkpoint/restore，**DPDK 不适用**  |
| **vhost-user migration** | QEMU 与 OVS-DPDK 通过专用消息协商设备状态         |
| **SR-IOV 透明迁移**      | mlx5 NIC 内部做状态同步，零停机                   |
| **最大坑**               | conntrack/NAT 不跨机迁移；满载业务永远不收敛      |

**生产最佳实践**：

1. **永远先关闭业务入口**（SLB 摘流），再迁
2. **大内存 VM 限速迁**（不要榨干交换带宽）
3. **准备 post-copy fallback**（pre-copy 卡住时降级）
4. **hugepage 充分预留**（避免目的端分配失败）
5. **同 NUMA 迁**（跨 NUMA 性能掉一半）
6. **OVS-DPDK conntrack 同步**（如果用 L4 业务）

---

## 参考资源

- [QEMU Live Migration](https://wiki.qemu.org/Features/LiveMigration)
- [QEMU migration parameters](https://www.qemu.org/docs/master/devel/migration.html)
- [libvirt domain migrate](https://libvirt.org/migration.html)
- [vhost-user protocol spec](https://qemu.readthedocs.io/en/v8.0/interop/vhost-user.html)
- [CRIU 官方](https://criu.org/)
- [VFIO migration](https://docs.kernel.org/driver-api/vfio.html)
- [mlx5 vfio-migration](https://enterprise-support.nvidia.com/s/article/HowTo-Configure-VFIO-Migration-on-ConnectX-5)
- [OVS conntrack TCP synchronization](https://docs.openvswitch.org/en/latest/tutorials/ovn-ic/)
- [Intel VT-d / IOMMU](https://software.intel.com/content/www/us/en/develop/articles/introduction-to-intel-virtualization-technology.html)
