---
title: ethtool 深度系列 Ch3：RSS 与多队列
date: 2026-04-17 19:00:00
tags: [Network, ethtool, RSS, SMP IRQ, IRQ Affinity, RPS, Multi-queue, CPU Affinity]
description: 深入讲解网卡多队列 RSS 原理、Toeplitz hash 算法、ethtool -L 队列配置、irqbalance 与 smp_affinity 绑定，以及虚拟网卡多队列。
---

# ethtool 深度系列 Ch3：RSS 与多队列

## 1. 单队列的瓶颈

```
单队列网卡时代：

NIC（1个队列）→ 单个 IRQ → CPU 0 → softirq → protocol stack
                     ↑
                 所有流量都走这里

瓶颈：
  - 中断密集：10Gbps × 64B小包 = 1560万中断/秒 → CPU 100% 单核
  - 无法并行：多核 CPU 只能用 1 个核处理网络
  - 延迟高：单核队列成为串行点
```

> [!note]
> 即使是 1G 网卡，高 PPS（每秒包数）场景下，单队列也会成为瓶颈。例如：DNS 请求（64B 小包）= 1Gbps / 64B ≈ 200万 PPS → CPU 单核 100%。

---

## 2. 多队列：硬件级并行

### 2.1 多队列原理

```
多队列网卡时代：

NIC（多个队列：queue 0~7）→ 8 个 IRQ → 8 个 CPU → 并行 protocol stack
  queue 0 ──────────────────▶ CPU 0
  queue 1 ──────────────────▶ CPU 1
  queue 2 ──────────────────▶ CPU 2
  ...
  queue 7 ──────────────────▶ CPU 7

优点：
  - 中断分散：每个队列中断率降低 8x
  - 并行处理：8 个 CPU 同时处理网络协议栈
  - 延迟低：包不排队，直接到专属 CPU
```

### 2.2 查看网卡队列数

```bash
# 查看当前配置的队列数
ethtool -l eth0

# output：
# Channel parameters for eth0:
# Pre-set maximums:
# RX:   8             ← 最大 RX 队列数
# TX:   8             ← 最大 TX 队列数
# Other: 0
# Combined: 0          ← combined 模式（每队列同时收+发）

# Current message level: 0x00000007 (7)
# Current device options: 0x00000001
# Combined: 8           ← 当前使用 8 个队列

# 查看每个队列的统计
ethtool -S eth0 | grep -E "tx-[0-9]|rx-[0-9]" | head -20

# output：
# rx-0: 1234567
# rx-1: 2345678
# tx-0: 987654
# tx-1: 876543
# ...
```

### 2.3 队列与 RSS 的关系

```
RSS（Receive Side Scaling）= 多队列 + 负载均衡

RSS hash 计算：
  hash = Toeplitz(src_ip, src_port, dst_ip, dst_port, protocol)
       ↓
  hash % num_queues = queue_index

同一个 flow（同一个 5-tuple）的包 → 同一个 hash → 同一个 queue
→ 保证 TCP 包的顺序（不会乱序）

不同 flow 的包 → 不同 hash → 分布到不同 queue
→ 负载均衡
```

---

## 3. Toeplitz Hash 算法

### 3.1 算法原理

```
Toeplitz hash = 用一个 key 对多个输入位做异或/AND 运算

key：NIC 固件或驱动分配的 40-bit（或 104-bit）随机值
        ↓
tuple：src_ip(32) + dst_ip(32) + src_port(16) + dst_port(16) + protocol(8)
        ↓
hash = 对 key 的不同 bit 位做掩码和异或

举例（简化版）：
  key = 0x3A (00111010)
  input = 0xF0 (11110000)

  hash = 0
  for each bit position i in key:
      if input[i] == 1:
          hash ^= key[i]

  即：对 input 中为 1 的 bit 位，把 key 对应 bit 异或进结果
```

### 3.2 为什么用 Toeplitz

```
Toeplitz vs 简单取模：

简单取模（不好）：
  queue = (src_ip ^ dst_ip) % 8
  问题：
    - 黑客可以构造特定 IP 制造 hash collision
    - 所有包打到同一个 queue → DoS 攻击
    - 不够随机

Toeplitz（好）：
  - key 是随机/伪随机的（黑客不知道）
  - 分布均匀（随机性来源于 key 的设计）
  - 抗碰撞（理论上很难人为制造碰撞）

查看/设置 RSS key：
  ethtool -x eth0              ← 查看 RSS key
  ethtool -X eth0 hfunc toeplitz ← 设置 hash 函数

# output（RSS indirection table）：
# RX flow hash indirection table:
#   0:      0     1     2     3     4     5     6     7
#   1:      1     2     3     4     5     6     7     0
#   ...
```

### 3.3 RSS Indirection Table

```
Indirection table = hash → queue 的映射表

每个 entry 对应一个 hash 值，每个 entry 指向一个 queue

# ethtool -x 输出解释：
# 通常 128 或 256 个 entry（hash 有 128/256 个可能值）

查看：
  ethtool -x eth0

# 修改 indirection table（手动调整负载分布）
ethtool -X eth0 equal 8
# equal = 平均分配（每队列分配相同数量 entry）

# 把更多 entry 指向 queue 0（queue 0 处理更多流量）
ethtool -X eth0 start 0 16
# start=0: 从 table index 0 开始
# count=16: 设置 16 个 entry

# 也可以用 hash key 直接控制
ethtool -X eth0 hfunc toeplitz
```

---

## 4. 配置多队列

### 4.1 ethtool -L 设置队列数

```bash
# 查看当前队列配置
ethtool -l eth0

# 设置队列数
ethtool -L eth0 combined 8
# combined 8 = 8 个队列，每个队列同时收+发

# 设置独立 RX/TX 队列数（某些网卡支持）
ethtool -L eth0 rx 8 tx 8
# rx 8 = 8 个 RX 队列
# tx 8 = 8 个 TX 队列

# 最小化队列数（省资源）
ethtool -L eth0 combined 1

# 最大队列数（性能最大化）
ethtool -L eth0 combined 16
# 不能超过 ethtool -l 显示的 maximum

# 注意：修改队列数可能需要重启网卡
ip link set eth0 down
ethtool -L eth0 combined 16
ip link set eth0 up
```

### 4.2 队列数与 CPU 核数的关系

```
最佳实践：队列数 ≈ CPU 核数（或略少）

理由：
  - 每个队列在 softirq 阶段由一个 CPU 处理
  - 如果队列数 > CPU 核数 → 某些 CPU 空转，浪费
  - 如果队列数 < CPU 核数 → 某些 CPU 闲着，浪费

例子：
  16 核 CPU + 16 队列网卡 → 完美匹配
  16 核 CPU + 8 队列网卡 → 每 2 个核共享一个队列（可接受）
  8 核 CPU + 16 队列网卡 → 浪费（最多用 8 个队列）

查看 CPU 核数：
  nproc
  # 或
  lscpu | grep "^CPU(s):"
```

### 4.3 查看队列中断绑定

```bash
# 查看所有网卡的 IRQ 分布
cat /proc/interrupts | grep -E "eth|mlx" | head -30

# output：
# 88:   123456   0   0   0   0  0  eth0-TxRx-0
# 89:   234567   0   0   0   0  0  eth0-TxRx-1
# 90:   345678   0   0   0   0  0  eth0-TxRx-2
# ...
# 列：IRQ# | CPU0 | CPU1 | CPU2 | ...
# 理想情况：每个队列的 IRQ count 差不多（负载均衡）

# 查看 eth0-TxRx-0 IRQ 的 CPU 亲和性
cat /proc/irq/88/smp_affinity
# output: 0001 = 只在 CPU 0 上处理

# 理想情况（8 核机器）：
# eth0-TxRx-0 → CPU 0
# eth0-TxRx-1 → CPU 1
# eth0-TxRx-2 → CPU 2
# ...

# 查看所有网卡的 smp_affinity（1行）
cat /proc/interrupts | grep eth0-TxRx | awk '{print $1, $NF, $(NF-1)}'
```

---

## 5. IRQ Affinity 配置

### 5.1 smp_affinity 绑定

```bash
# 每个 CPU 有一个 bit mask
# bit 0 = CPU 0, bit 1 = CPU 1, ...
# 0x01 = CPU 0
# 0x03 = CPU 0 + CPU 1
# 0xff = 所有低 8 位 CPU（0-7）
# ffffffff = 所有 32 个 CPU

# 把 eth0-TxRx-0（IRQ 88）绑定到 CPU 0
echo 1 > /proc/irq/88/smp_affinity

# 绑定到 CPU 0 和 CPU 1（负载均衡）
echo 3 > /proc/irq/88/smp_affinity

# 绑定到 CPU 4
echo 10 > /proc/irq/88/smp_affinity
# 10（16进制）= 10000（2进制）= 第 4 个 CPU

# 确认绑定
cat /proc/irq/88/smp_affinity
# 输出：00000001（16进制）
```

### 5.2 自动绑定脚本

```bash
#!/bin/bash
# set_irq_affinity.sh
# 把 eth0 的所有队列 IRQ 绑定到对应的 CPU

IFACE=${1:-eth0}
NUM_CPUS=$(nproc)

# 找到 eth0 相关的 IRQ
for irq_path in /proc/irq/*/ssid/${IFACE}-*; do
    irq=$(basename $(dirname $irq_path))
    queue_num=$(echo $irq_path | grep -o '[0-9]*$')

    # CPU 绑定：queue_num % num_cpus
    cpu=$((queue_num % NUM_CPUS))
    mask=$((1 << cpu))

    echo "IRQ $irq (queue $queue_num) → CPU $cpu (mask: $mask)"
    echo $mask > /proc/irq/$irq/smp_affinity 2>/dev/null
done
```

### 5.3 irqbalance 守护进程

```
irqbalance = 自动管理 IRQ 亲和性的 daemon

系统默认会启动 irqbalance：
  systemctl status irqbalance

irqbalance 的策略：
  - 按 IRQ 类型分配到不同 CPU（网络、存储、计时器分开）
  - 按负载动态迁移（热点 CPU 降权）
  - 避免太多 IRQ 集中在一个 CPU

问题：
  - irqbalance 可能把网络 IRQ 迁到不该去的 CPU
  - 实时性要求高的场景 → 关掉 irqbalance，手动绑定

关闭 irqbalance（延迟敏感场景）：
  systemctl stop irqbalance
  systemctl disable irqbalance
```

### 5.4 查看 softirq 负载

```bash
# 看哪个 CPU 在处理网络 softirq
mpstat -P ALL 1 5 | grep -E "CPU|all"
# %idle 列：idle 100% → 很闲
# %softirq 列：有值 → 在处理软中断

# 实时监控 softirq
watch -n1 'cat /proc/softirqs | grep NET'

# output：
#           CPU0       CPU1       CPU2       CPU3
# NET_RX:   123456     987654     456789     234567
# NET_TX:   234567     345678     456789     567890
# NET_RX：网络收包软中断（越高 → 流量越大）
# NET_TX：网络发包软中断

# 如果 CPU0 的 NET_RX 远高于其他 CPU
# → 流量没有均衡分发 → 检查 RSS 配置
```

---

## 6. RPS：没有 RSS 网卡的软件替代

### 6.1 RPS 原理

```
RPS = Receive Packet Steering（软件模拟 RSS）

适用场景：
  - 虚拟网卡没有 RSS（virtio-net 老版本）
  - 网卡队列数 < CPU 核数
  - 想更细粒度控制包分发

原理：
  NIC 收到包 → 1 个 IRQ → 1 个 CPU（硬件）
    ↓
  该 CPU 的 softirq 阶段，RPS 查表决定：
    → 本 CPU 处理 OR
    → 重定向到其他 CPU（通过 softirq pending）

配置位置：
  /sys/class/net/<iface>/queues/rx-<n>/rps_cpus

rps_cpus 是一个 bitmask：
  echo ff > /sys/class/net/eth0/queues/rx-0/rps_cpus
  # 0xff = 低 8 位 CPU（0-7）都可以处理这个队列的包
```

### 6.2 RPS 配置脚本

```bash
#!/bin/bash
# enable_rps.sh — 给所有 CPU 启用 RPS

IFACE=${1:-eth0}
NUM_CPUS=$(nproc)

# 生成 bitmask（如果 16 核，mask=ffff）
MASK=$(printf '%.0sx' $(($NUM_CPUS/4)) | sed 's/x/ffff/g' | tail -c 8)
# 更简单：
MASK=$(echo "obase=16; 2^$NUM_CPUS - 1" | bc | tr -d '\\\n')

for rps_file in /sys/class/net/$IFACE/queues/rx-*/rps_cpus; do
    echo "$MASK" > $rps_file
    echo "RPS enabled: $rps_file → $MASK"
done
```

---

## 7. 虚拟网卡多队列

### 7.1 virtio-net 多队列

```
KVM 虚拟网卡 virtio-net 的多队列：

宿主机侧：
  vhost-net 驱动 → 多个 vhost queue

虚拟机侧：
  virtio-net → 多个 virtqueue

配置：
  # 虚拟机 XML 配置
  <interface type='virtio'>
    <driver name='vhost' queues='4'/>
  </interface>
  queues=4 → 4 对 TX/RX virtqueue

查看虚拟机内：
  ethtool -l eth0
  # Channel parameters for eth0:
  # Pre-set maximums:
  # RX:   8
  # TX:   8
  # Combined: 8
  # Current: 8                            ← 虚拟机看到了 8 个队列

宿主机侧查看：
  # vhost-net 的队列数 = 虚拟机的队列数
  cat /sys/class/net/vnet0/queues/*/tid
```

### 7.2 vhost-net 调优

```bash
# 查看 vhost-net 统计
cat /proc/net/vstat/vhost

# 查看虚拟机 vhost queue 绑定
ls /sys/class/net/vnet0/queues/
# rx-0  rx-1  rx-2  rx-3  tx-0  tx-1  tx-2  tx-3

# vhost-net 的 interrupt coalescing
# /sys/class/net/vnet0/queues/*/bytes
# 控制每个队列的批量处理

# 调优参数：
# /sys/module/vhost/parameters/
#   vhost_nr_mem_tracker: vhost 内存跟踪
#   max_iotlb_entries: IOTLB 最大条目

# 虚拟机 virtio-net 支持 indirect descriptor（省 copy）
ethtool -k eth0 | grep "virtio net"
# 如果 virtio 1.1+ 支持：indirect usebuf=on
```

### 7.3 VMware vmxnet3 多队列

```
vmxnet3 多队列配置：

vSphere Client → VM → Edit Settings → Network adapter →
  Advanced → Number of Rx Buffers: 64
  → 可以增加 Rx queue 数

或者在 ESXi host 上：
  esxcli system module parameters set -m vmxnet3 -p "rss=$int"

查看：
  ethtool -l vmnic0   # ESXi host 侧
  ethtool -l eth0     # 虚拟机内
```

---

## 8. 实战：多队列配置案例

### 8.1 案例：配置 16 核机器的 16 队列网卡

```bash
#!/bin/bash
# optimize_nic_queues.sh

IFACE=${1:-eth0}
NUM_CPUS=$(nproc)

echo "=== 系统配置 ==="
echo "CPU 核数: $NUM_CPUS"
echo "网卡: $IFACE"

# 1. 设置 16 队列
echo "--- 设置 ${NUM_CPUS} 队列 ---"
ethtool -L ${IFACE} combined ${NUM_CPUS}

# 2. 关闭 irqbalance（手动绑定）
systemctl stop irqbalance

# 3. 绑定每个队列 IRQ 到不同 CPU
echo "--- 绑定 IRQ 到 CPU ---"
for i in $(seq 0 $((NUM_CPUS-1))); do
    irq_file=$(find /proc/irq -name "*${IFACE}*" | grep -E "TxRx-${i}$|TxRx-${i}\s" | head -1)
    if [ -n "$irq_file" ]; then
        irq=$(basename $(dirname $irq_file))
        mask=$((1 << i))
        echo $mask > /proc/irq/$irq/smp_affinity
        echo "IRQ $irq (queue $i) → CPU $i (mask=$mask)"
    fi
done

# 4. 开启 RPS（补充 RSS）
echo "--- 启用 RPS ---"
for rps in /sys/class/net/${IFACE}/queues/rx-*/rps_cpus; do
    echo ff > $rps 2>/dev/null || true
done

# 5. 开启 GRO（提高吞吐）
ethtool -K ${IFACE} gro on

# 6. 查看结果
echo "--- 验证配置 ---"
ethtool -l ${IFACE}
echo ""
echo "IRQ 绑定："
cat /proc/interrupts | grep ${IFACE} | awk '{print $1, $NF, $(NF-1)}'
```

### 8.2 案例：排查 RSS 不均衡（单核负载高）

```bash
# Step 1: 查看各队列 rx 统计
ethtool -S eth0 | grep -E "^rx-[0-9]+:" | sort -t: -k2 -rn | head -10

# output：
# rx-0: 987654321    ← queue 0 明显比其他多很多！
# rx-1: 123456789
# rx-2: 98765432
# rx-3: 98765433
# ...

# 原因：流量集中在少数 flow（比如单 client 访问）
#      它们的 hash 相同 → 同一个 queue

# Step 2: 检查 RSS hash key
ethtool -x eth0 | head -5

# Step 3: 重新分配 indirection table（把 queue 0 的 entry 分散）
# 方案 1: equal（平均分配，但 flow 还是会 hash 到原 queue）
ethtool -X eth0 equal 8

# 方案 2: 把所有 entry 都指向 queue 0（不推荐，完全失去并行）
# ethtool -X eth0 weighted 8 8 8 8 8 8 8 8

# 方案 3: 实际解决方案 - 确认是否是 NAT/负载均衡问题
#  如果源 IP 相同 → 所有包 hash 相同 → 必然单 queue
#  → 正常现象，队列多没用
#  → 真正解决：在网络架构上增加源 IP 数量（ECMP/负载均衡器）

# Step 4: 如果是某 IP 流量太大（而非 IP 太少）
# 查看是哪个 IP
ss -tunapl | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -5
```

### 8.3 案例：高性能 HTTP 服务器优化

```bash
# 场景：8 核机器跑 nginx，期望最大化吞吐

# 1. 网卡配置
ethtool -L eth0 combined 8
ethtool -K eth0 tso on gso on gro on
ethtool -G eth0 rx 4096 tx 4096  # 增大 ring buffer

# 2. RPS（虚拟机或旧网卡）
for f in /sys/class/net/eth0/queues/rx-*/rps_cpus; do
    echo ff > $f
done

# 3. nginx 配置（绑定到 8 个 worker）
# /etc/nginx/nginx.conf
worker_processes auto;
worker_cpu_affinity auto;
# auto 会根据 CPU 核数自动分配

# 4. nginx worker connections
# /etc/nginx/nginx.conf
events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

# 5. 系统参数
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.wmem_max=16777216
sysctl -w net.ipv4.tcp_rmem="4096 87380 16777216"
sysctl -w net.ipv4.tcp_wmem="4096 65536 16777216"

# 6. 测试
iperf3 -s -c 127.0.0.1 -t 30  # 本机回环测试
# 如果回环比 eth0 快 → 网卡瓶颈
# 如果 eth0 也很快 → 系统配置到顶
```

---

## 9. 小结

```
RSS = 硬件多队列 + Toeplitz hash + Indirection Table

队列配置：
  ethtool -l eth0         查看队列数
  ethtool -L eth0 combined 8  设置 8 队列

IRQ 绑定：
  /proc/interrupts        查看中断分布
  /proc/irq/<n>/smp_affinity  设置 CPU 亲和性
  irqbalance               自动均衡（延迟敏感场景关闭）

Toeplitz hash：
  ethtool -x eth0          查看 hash key
  ethtool -X eth0 hfunc toeplitz  设置 hash 算法
  ethtool -X eth0 equal    平均分配 indirection table

RPS（软件 RSS）：
  /sys/class/net/eth0/queues/rx-<n>/rps_cpus
  当网卡不支持 RSS 时，在 softirq 层做软件分流

队列数选择：
  队列数 ≈ CPU 核数
  多核 CPU 共享少量队列 → 单核瓶颈

虚拟网卡多队列：
  virtio-net: queues=N（KVM）
  vmxnet3: ESXi 高级设置
```

---

## 延伸阅读

- `man ethtool` — ethtool -L / -X 选项
- Kernel doc: `Documentation/networking/scaling.txt` — RSS + RPS + RFS
- Kernel doc: `Documentation/networking/iropenx.txt` — 中断处理
- Intel 82599 datasheet: RSS Hash — Toeplitz 算法详解
- Mellanox MLX5: `drivers/net/ethernet/mellanox/mlx5/core/en/rep/tc_tir.c`
- Vhost-net: `Documentation/virt/vhost/`
