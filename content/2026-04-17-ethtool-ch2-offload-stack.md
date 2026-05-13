---
title: ethtool 深度系列 Ch2：Offload 全家桶
date: 2026-04-17 18:00:00
tags: [Network, ethtool, GRO, GSO, TSO, UFO, checksum, offload, RSS, RPS]
description: 深入讲解 Linux 网卡 Offload 机制：Checksum、GSO、TSO、GRO、UFO 的工作原理、协作关系，以及何时开启/关闭对性能的影响。
---

# ethtool 深度系列 Ch2：Offload 全家桶

## 1. 为什么需要 Offload

```
传统发送（CPU 做所有事）：
  应用：构造 HTTP 响应
    ↓
  TCP stack：计算 checksum（每 byte 遍历一遍）
    ↓
  IP layer：计算 IP header checksum（每 byte 遍历一遍）
    ↓
  Driver：发送 DMA

  问题：Checksum 计算是纯 CPU 操作，1Gbit/s 流量下
       → CPU 每秒做 1G/8 = 125MB 的 checksum 计算
       → 10Gbit/s → 1.25GB/s → CPU 占用率显著

Offload：
  把校验、分片、组包的工作交给网卡硬件
  → CPU 只做一次指令发给网卡
  → 1 个 64KB HTTP 响应 → 1 次发指令 → 网卡做分片+checksum
  → CPU 占用率从 30% → 2%
```

> [!note]
> Offload 不是"更好"，而是"更适合某些场景"。高并发小包场景（Redis）可能需要关闭 TSO 获得更精确的拥塞控制。

---

## 2. Offload 家族全景图

```
发送路径（Tx）：

应用数据（64KB HTTP response）
        │
        ▼
  TCP socket buffer
        │
        ▼
  ┌─────────────────────────────────┐
  │  GSO (Generic Segmentation Offload) │
  │  把大 TCP 包分片成 MTU 大小的包    │
  │  但 checksum 还在 CPU 算          │
  └──────────────┬──────────────────┘
                 │ (分成多个 MTU 包)
                 ▼
  ┌─────────────────────────────────┐
  │  TSO (TCP Segmentation Offload)  │
  │  把大 TCP 包分片 + 算 checksum   │
  │  → 需要 NIC 支持（intel igb+)    │
  └──────────────┬──────────────────┘
                 │ (分片好的 MTU 包)
                 ▼
  ┌─────────────────────────────────┐
  │  Checksum Offload (TX)           │
  │  NIC 算 TCP/UDP/IP checksum      │
  └──────────────┬──────────────────┘
                 │
                 ▼
  ┌─────────────────────────────────┐
  │  DMA（直接内存搬运，无 CPU 介入）  │
  └─────────────────────────────────┘
                 │
                 ▼
              NIC 发送


接收路径（Rx）：

NIC 接收（多个 MTU 包，可能有 GRO 合并）
        │
        ▼
  ┌─────────────────────────────────┐
  │  GRO (Generic Receive Offload)    │
  │  把多个 TCP 包合并成大包          │
  │  交给 TCP stack 一个完整的包      │
  └──────────────┬──────────────────┘
                 │
                 ▼
  ┌─────────────────────────────────┐
  │  Checksum Offload (RX)           │
  │  NIC 验证 checksum，设 flag      │
  │  TCP stack 不再算（skb->ip_summed）│
  └──────────────┬──────────────────┘
                 │
                 ▼
        TCP socket buffer → 应用
```

---

## 3. 查看 Offload 状态

### 3.1 ethtool -k

```bash
# 查看所有 offload 状态
ethtool -k eth0

# output：
# Features for eth0:
# tcp-segment-offload: on                    ← TSO
# scatter-gather: on                         ← SG（TSO 依赖）
# generic-segment-offload: on                ← GSO
# generic-receive-offload: on                 ← GRO
# rx-checksumming: on                        ← RX checksum
# tx-checksumming: ipv4 on                   ← TX IPv4 checksum
# tx-checksumming: ipv6 on                   ← TX IPv6 checksum
# tx-checksum-ipv4: on                       ← 驱动专属（ip 层）
# tx-checksum-ipv6: on                       ← 驱动专属（IPv6）
# udp-fragmentation-offload: on              ← UFO
# scatter-gather: on                         ← SG
#     tx-scatter-gather: on
#     tx-scatter-gather-fraglist: on         ← fraglist SG
# tcp-fragmentation-offload: on              ← TSO（同 tcp-segment-offload）
# highdma: on [fixed]                        ← High DMA（Hub）
#修真协助？
# vlan-chimney-chimney-offload: off
# generic-header-helpers: on
# tiny-fragment-offload: off                  ← 小分片
# l2-fwd-offload: off [fixed]                ← L2 Forwarding（switch ASIC）
# esp-hw-offload: off                        ← IPSec offload（需要 hw)
# esp-tx-csum-offload: off
# vxlan-offload: off                         ← VxLAN offload
# vxlan-migration-offload: off
# fcoe-offload: off                          ← FC over Ethernet
# mbcache-offload: off
# wifi-offload: off
# device-specific spoof-sorting-offload: off
# tls-hardware-offload: off                  ← TLS offload
# restendant-tx-tagging: off
# arp-offload: off                           ← ARP offload
# negotiate: off
```

### 3.2 字段解释

| 特性                              | 作用                                 | 依赖                 |
| --------------------------------- | ------------------------------------ | -------------------- |
| `tcp-segment-offload` (TSO)       | 网卡做 TCP 分片+checksum             | scatter-gather       |
| `generic-segment-offload` (GSO)   | 分片在协议栈做，checksum 在驱动做    | 无                   |
| `generic-receive-offload` (GRO)   | 接收合并多个小包成大包               | 无                   |
| `rx-checksumming`                 | 网卡验证 RX checksum                 | 无                   |
| `tx-checksumming`                 | 网卡算 TX checksum（TCP/UDP/IP）     | 无                   |
| `udp-fragmentation-offload` (UFO) | UDP 分片 offload                     | 无                   |
| `scatter-gather`                  | 支持 SG list（分散的内存块一次 DMA） | 无                   |
| `esp-hw-offload`                  | IPSec 加密 offload                   | 硬件支持             |
| `vxlan-offload`                   | VxLAN 封装/解封装 offload            | 硬件支持             |
| `tls-hardware-offload`            | TLS 加密 offload                     | 硬件支持（最新网卡） |
| `highdma`                         | 允许 DMA 访问高地址内存              | 硬件+驱动支持        |

---

## 4. TSO：TCP Segmentation Offload

### 4.1 TSO 工作原理

```
场景：应用要发送 64KB HTTP 响应（MTU=1500）

没有 TSO（CPU 分片）：
  TCP stack 构造 64KB 数据
    ↓
  CPU 分成 ~44 个 1500 字节的包（每包算 IP+TCP checksum）
  44 × 1500 = 66000 ≈ 64KB
    ↓
  每个包都要 CPU 介入（分片 + checksum）
  → CPU 负载高

有 TSO（网卡分片）：
  TCP stack 构造 64KB 数据，一次性给网卡
    ↓
  NIC 硬件自动分成 ~44 个 1500 字节包
  每个包的 IP+TCP header 和 checksum 都是硬件算的
    ↓
  CPU 只有一个操作（一次 DMA 提交）
  → CPU 负载极低
```

### 4.2 查看 TSO 效果

```bash
# 看 eth0 的 TSO 状态
ethtool -k eth0 | grep tcp-segment

# 关闭 TSO
ethtool -K eth0 tso off

# 开启 TSO
ethtool -K eth0 tso on

# 验证关闭
ethtool -k eth0 | grep tcp-segment-offload

# 测试 TSO 开/关的性能差异
# 用 iperf3 测试
# server: iperf3 -s
# client: iperf3 -c SERVER_IP -t 60

# TSO on 时：CPU 占用率低，吞吐高
# TSO off 时：CPU 占用率显著上升（做分片）
# 如果关闭后吞吐反而高了 → 瓶颈在 CPU，offload 降低了效率
```

### 4.3 TSO 的限制

```
MTU 限制：
  TSO 最大 segment size = 网卡支持的最大值
  常见网卡最大：16KB / 64KB
  TSO 在 MTU=1500 时分 ~44 个包
  TSO 在 MTU=9000 时分 ~7 个包（更少 CPU 开销）

包大小限制：
  skb（socket buffer）必须 > MTU 才有用
  实时交互流量（小包 < MTU）→ TSO 完全不参与

协议限制：
  TSO 只对 TCP 有效
  UDP → UFO（UDP Fragmentation Offload）
  ICMP → 不支持
```

---

## 5. GSO：Generic Segmentation Offload

### 5.1 GSO vs TSO

```
GSO 是"软件版"的 TSO：
  - TSO 需要网卡硬件支持（igb/ixgbe/i40e/mlx5）
  - GSO 是 TCP stack 自己做分片（在没有 TSO 能力的网卡上）
  - 有 TSO 硬件时，GSO 可以把分片直接 offload 给 TSO

流程（没有 TSO 硬件时）：
  应用数据（64KB）
    ↓
  GSO（在 kernel 网络层分片）
    ↓
  ~44 个 1500 字节包
    ↓
  驱动算每个包的 checksum（如果没有 checksum offload）
    ↓
  网卡 DMA

GSO 的价值：
  - 让没有 TSO 硬件的网卡也能减少 CPU checksum 开销
  - 提供统一的分片接口，不管网卡有没有 TSO
```

### 5.2 GSO 与 TSO 的关系

```
查看 TSO/GSO 状态：
  ethtool -k eth0 | grep -E "segment|generic"

4种组合：

1. TSO on, GSO on（最优）：
   应用 → TCP → GSO → TSO → NIC → 发送
   CPU 只做一次分片（GSO），剩余全在硬件

2. TSO off, GSO on：
   应用 → TCP → GSO（CPU 分片）→ checksum CPU → NIC
   GSO 分片，CPU 算 checksum
   性能不如 #1，但比完全不分片好

3. TSO on, GSO off（无效组合）：
   → 内核通常不允许这种组合
   → TSO 依赖 GSO 提供原始数据

4. TSO off, GSO off：
   → 完全软件处理，最高 CPU 开销
   → 只在排查问题时用
```

---

## 6. GRO：Generic Receive Offload

### 6.1 GRO 工作原理

```
接收 1000 个 HTTP 请求（每个 1500 字节）

没有 GRO：
  NIC 收到 1000 个包 → 1000 次中断
    ↓
  每个包独立上送到 TCP stack
    ↓
  TCP stack 独立处理每个包的开销（每个包一次协议处理）
    ↓
  CPU 处理 1000 次中断 + 1000 次 TCP 处理

有 GRO：
  NIC 收到 1000 个包 → 硬件合并成 ~10 个大包
    ↓
  10 次中断（减少 100x 中断）
    ↓
  TCP stack 每次处理一个合并后的大包（包含多个原始包）
    ↓
  减少 CPU 中断和处理开销
```

### 6.2 GRO 合并算法

```
GRO 不是简单的 concat，是按 "flow" 合并：

Flow 识别（5-tuple）：
  (src_ip, dst_ip, src_port, dst_port, protocol)

同一 flow 的包才能合并：
  包 1: HTTP req to 10.0.0.1:443, seq=1000, len=1000
  包 2: HTTP req to 10.0.0.1:443, seq=2000, len=1000
  包 3: HTTP req to 10.0.0.1:443, seq=3000, len=1000
  → 合并成一个 skb，seq=1000, len=3000

不同 flow 的包不合并：
  包 1: to 10.0.0.1:443
  包 2: to 10.0.0.2:443
  → 同一时间给 TCP stack 两个包
```

### 6.3 GRO 对抓包的影响

```bash
# 抓包时关闭 GRO（避免看到合并的包）
ethtool -K eth0 gro off

# 然后 tcpdump：
tcpdump -i eth0 -nn 'port 443'
# 不关 GRO：tcpdump 可能只看到合并后的大包（不像原始发送的包）

# 为什么重要？
# Wireshark 分析时：
#   gro on → 看到的是协议栈收到的包（已合并）
#   gro off → 看到的是网卡实际收到的原始包
#   对于延迟分析、丢包定位，gro off 更准确

# GRO 对 TCP retransmit 的影响：
#   GRO 合并多个包后，如果中间丢了一个
#   → 整个合并的 skb 都需要 retransmit
#   → 可能影响性能
#   高可靠场景：关闭 GRO
```

### 6.4 LRO（已废弃）

```
LRO = Link Receive Offload（已被 GRO 取代）

LRO 的问题：
  - 把不同 flow 的包也合并（不安全）
  - 不符合 RFC
  - 无法和 iptables/nf_conntrack 配合

现代 Linux：
  ethtool -k eth0 | grep lro
  # 不存在（已移除）
  # 用 gro 代替 lro
```

---

## 7. Checksum Offload

### 7.1 TX Checksum

```bash
# 查看 TX checksum 状态
ethtool -k eth0 | grep "tx-checksum"

# output：
# tx-checksumming: on
# tx-checksum-ipv4: on           ← TCP/UDP over IPv4
# tx-checksum-ipv6: on           ← TCP/UDP over IPv6

# 关闭 TX checksum offload（调试用）
ethtool -K eth0 tx-checksum-ipv4 off

# 关闭后：
# 性能下降（CPU 算 checksum）
# 但某些场景需要关闭：
#   - 网卡 checksum 验证有 bug
#   - 抓包时看到 checksum error（抓的是已 offload 的数据）
#   - 使用 VxLAN 时某些网卡不支持 checksum offload
```

### 7.2 RX Checksum

```bash
# 查看 RX checksum 状态
ethtool -k eth0 | grep "rx-checksum"

# output：
# rx-checksumming: on

# 关闭 RX checksum offload
ethtool -K eth0 rx-checksum off

# 关闭后的现象：
# tcpdump 看不到 "正确的 checksum"
# 包会显示 "wrong checksum"（但实际上可能没问题）
# 这是因为关闭后 kernel 不再信任网卡的验证，自己再算一遍

# 场景：某些协议检测工具需要关闭 checksum offload
# 否则看到错误的 checksum 误报
```

### 7.3 Checksum offload 原理

```
RX checksum offload 流程：

NIC 收到帧
    ↓
NIC 计算 Ethernet/IP/TCP checksum（硬件）
    ↓
DMA 把包+checksum 结果送到 RAM
    ↓
驱动读取 skb，标记 ip_summed:
    CHECKSUM_NONE          → 不校验（应用层自己处理）
    CHECKSUM_UNNECESSARY   → 硬件已校验，信任
    CHECKSUM_COMPLETE      → 驱动自己校验了
    CHECKSUM_PARTIAL      → UDP/TCP 有问题（不完整）

TCP stack 收到 skb：
    if (skb->ip_summed == CHECKSUM_UNNECESSARY)
        → 不再算 checksum，跳过
    else
        → TCP stack 自己算一遍

结果：CPU 每包少做一次 checksum 运算
```

---

## 8. UFO：UDP Fragmentation Offload

### 8.1 UFO vs TSO

```
UFO = UDP Fragmentation Offload

原理同 TSO，但是 UDP：
  应用发 64KB UDP 数据报
    ↓
  UFO：网卡分成 MTU 大小的 UDP 包
  每个包的 IP+UDP header + checksum 都是硬件算
    ↓

为什么没有 "USO" 统一命名？
  因为 UDP 的分片在 IP 层（IP fragmentation）
  而 TCP 的分片在 TCP 层（segmentation）
  概念不同所以名字不同

查看 UFO 状态：
  ethtool -k eth0 | grep udp-fragmentation

注意：
  UFO 需要硬件支持（Mellanox mlx5 支持）
  虚拟网卡通常不支持 UFO
```

---

## 9. Scatter-Gather（SG）

### 9.1 SG 原理

```
传统 DMA：需要连续的物理内存
  skb 数据必须连续 → 如果内存碎片化 → 需要 copy 到连续区域

Scatter-Gather DMA：
  把多个物理上不连续的内存块组成一个 frame 发送
  → 不需要 copy
  → 减少内存分配压力

查看 SG：
  ethtool -k eth0 | grep scatter

# scatter-gather: on
#     tx-scatter-gather: on
#     tx-scatter-gather-fraglist: on   ← 更高级的 fraglist 模式
```

### 9.2 SG 对性能的影响

```
场景：高性能文件传输（sendfile）

sendfile() 系统调用：
  文件 → socket，直接 DMA（零拷贝）
  依赖 SG：文件内容可能分散在多个物理页

没有 SG：
  文件 → 读入连续 buffer → copy 到 socket
  → 多一次内存 copy

有 SG：
  文件 → 直接 DMA 到网卡（SG 把不连续的页拼接）
  → 零拷贝
```

---

## 10. RPS/RFS：软件分流（网卡不支持 RSS 时）

### 10.1 RPS（Receive Packet Steering）

```
RPS = 软件版的 RSS

背景：
  RSS（硬件）需要网卡支持（modern NIC）
  旧网卡/虚拟网卡没有 RSS
  → 所有流量进一个 CPU queue → CPU 单核瓶颈

RPS 解决方案：
  NIC 收到包 → 单个 IRQ → 单个 CPU 处理
    ↓
  但在软中断（softirq）阶段
  RPS 可以把包"重定向"到其他 CPU

配置 RPS：
  # /sys/class/net/eth0/queues/rx-0/rps_cpus
  # 16 核机器：echo ff > /sys/class/net/eth0/queues/rx-0/rps_cpus
  # ff = 16 进制 = 11111111 = 8 个 CPU（低 8 位）
  # ffff = 16 个 CPU

查看：
  cat /sys/class/net/eth0/queues/rx-0/rps_cpus
```

### 10.2 RFS（Receive Flow Steering）

```
RFS = RPS + flow locality（流本地性优化）

RPS 的问题：
  包 A（flow 1）→ CPU 1 处理
  包 B（flow 1）→ CPU 3 处理
  → 同一个 flow 在不同 CPU 的 cache 不共享
  → 可能丢包（同一 flow 乱序）

RFS 的改进：
  跟踪每个 flow 应该在哪个 CPU 处理
  优先把 flow 送到处理过它的 CPU（cache 热）
  → 更高效的缓存利用

开启 RFS：
  # 默认开启（rfs_flow_count = 65536）
  sysctl -a | grep rfs

  # 查看：
  cat /proc/sys/net/core/rps_flow_cnt

  # 调整：
  echo 262144 > /proc/sys/net/core/rps_sock_flow_entries
```

### 10.3 aRFS（accelerated RFS）

```
aRFS = hardware-assisted RFS

需要网卡支持 flow director（Intel i40e/ixgbe）

流程：
  RSS hash → 网卡直接按 hash 把包放到对应 queue
  但 aRFS 还做了 CPU affinity 优化

查看是否支持：
  ethtool -k eth0 | grep ntuple
  # ntuple-filters: off → 不支持 aRFS

开启 ntuple filter：
  ethtool -K eth0 ntuple on
```

---

## 11. 实战：何时开关 Offload

### 11.1 抓包场景

```bash
# 问题：tcpdump 抓到的包 checksum 显示错误
# 原因：网卡的 checksum offload 把包直接发给 tcpdump（绕过了 stack）
#       tcpdump 在软中断后抓，看到的是 offload 前的状态（checksum 未算）

# 解法 1：关闭 TX checksum offload（抓出方向）
ethtool -K eth0 tx-checksum-ipv4 off
tcpdump -i eth0 -nn 'port 80'
# 现在看到的是 CPU 算好的 checksum

# 解法 2：关闭 RX checksum offload（抓入方向）
ethtool -K eth0 rx-checksum off
tcpdump -i eth0 -nn 'port 80'

# 解法 3：用 -even0（抓原始设备）
tcpdump -i eth0 -nn
# 通常够用，checksum 问题只在特定场景影响分析
```

### 11.2 排查网络问题

```bash
# 场景：突然大量丢包，但 ethtool -S 没有 rx_dropped

# Step 1：关闭 GRO（GRO 可能掩盖真实的丢包）
ethtool -K eth0 gro off

# Step 2：关闭 TSO/GSO（让 TCP 看到真实的分片行为）
ethtool -K eth0 tso off gso off

# Step 3：抓包看是否有异常
tcpdump -i eth0 -nn 'tcp'

# 常见问题：
# TSO on 时，TCP 以为发了大包，但网卡实际丢在了分片环节
# 关闭 TSO 后，丢包会在 TCP 层表现出来

# 验证是 TSO 问题：
# 关闭 TSO 后 iperf3 吞吐恢复正常 → 确认是 TSO/GSO bug 或瓶颈
```

### 11.3 关闭所有 offload 基准测试

```bash
# 测试 offload 对性能的影响
# 先关闭所有 offload 作为 baseline
ethtool -K eth0 \
    tso off gso off gro off \
    rx-checksum off tx-checksum-ipv4 off \
    ufo off

# iperf3 测 baseline 吞吐
iperf3 -c SERVER_IP -t 60

# 再逐个开启，找最优配置
ethtool -K eth0 gro on
iperf3 -c SERVER_IP -t 60

ethtool -K eth0 tso on
iperf3 -c SERVER_IP -t 60
# ...

# 注意：
#   吞吐高了 ≠ 延迟低了
#   Redis/游戏需要低延迟 → 关闭 GRO 可能更好
#   文件传输/HTTP bulk → 开启 GRO+TSO 吞吐更高
```

### 11.4 虚拟化场景

```bash
# KVM/libvirt 虚拟机网卡 offload 配置
# /etc/libvirt/qemu/vm.xml

# 方式 1：virsh edit 配置 offload
# <driver name='vhost' queues='4'>
#   <host ebtable='ebtable'/>
#   <tune sock_sndbuf='0'/>
# </driver>

# 方式 2：qemu 命令行
# -netdev virtio-net-pci,id=net0,vectors=4,\
#   mq=on,offload=off

# 虚拟机内关闭 offload（排查问题）
ethtool -K eth0 tso off gso off gro off
# 虚拟机内 virtio 驱动对 offload 支持有限
# 关闭可能更稳定

# 查看虚拟机 virtio 支持的 offload
ethtool -k eth0
# virtio 的 GRO 是"fake GRO"（软件合并，性能有限）
```

---

## 12. 小结

```
Offload 分层（从上到下，从软到硬）：

应用数据（64KB）
    ↓
  GSO：kernel 层分片（无 TSO 硬件时）
    ↓
  TSO：网卡硬件分片（TCP）
    ↓
  Checksum Offload：网卡算校验和
    ↓
  DMA：直接内存访问

接收对应：
  DMA → GRO（合并） → Checksum 验证 → TCP stack

查看：
  ethtool -k eth0          所有 offload 状态
  ethtool -K eth0 tso off  关闭 TSO
  ethtool -K eth0 gro off  关闭 GRO

什么时候关闭 offload：
  1. 抓包看到错误 checksum → 关闭 checksum offload
  2. 排查丢包 → 关闭 GRO/TSO 看真实丢包点
  3. 小包交互场景（Redis）→ 关闭 TSO 改善延迟
  4. 虚拟机 virtio 驱动不稳 → 关闭

RPS/RFS：
  虚拟网卡没有 RSS 时的软件替代
  echo ff > /sys/class/net/eth0/queues/rx-0/rps_cpus
```

---

## 延伸阅读

- `man ethtool` — ethtool -k/-K 选项
- Kernel doc: `Documentation/networking/net_capa.txt` — checksum offload
- Kernel doc: `Documentation/networking/tso.rst` — TSO 描述
- Kernel doc: `Documentation/networking/scaling.txt` — RPS/RFS
- Intel i40e driver: `drivers/net/ethernet/intel/i40e/`
- Mellanox mlx5: `drivers/net/ethernet/mellanox/mlx5/core/`
