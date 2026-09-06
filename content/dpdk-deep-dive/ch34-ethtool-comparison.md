---
title: "DPDK 深度探索 ch34：dpdk-procinfo、ethtool、ss 与现代网络诊断工具全景对比"
date: 2026-04-09 15:44:00
tags:
  [dpdk, ethtool, netstat, ss, ip, dpdk-procinfo, telemetry, prometheus, debugging, observability]
description: "深入对比 Linux 网络诊断工具链：ethtool / ss / ip / dpdk-procinfo / VPP show / OVS-DPDK ofctl 的能力边界、典型场景、组合使用与可观测性集成"
---

# DPDK 深度探索 ch34：dpdk-procinfo、ethtool、ss 与现代网络诊断工具全景对比

> [!info] 关联章节
>
> - [[ch31-debugging-tools|ch31 调试工具——dpdk-devbind、ethtool]]（设备绑定与基础 ethtool）
> - [[ch29-profiling|ch29 性能分析]]（perf / ftrace / bpf）
> - [[ch30-performance-tuning|ch30 性能调优]]（队列、Mbuf、IRQ affinity）
> - [[ch43-tools-debug|ch43 工具与调试]]（全套工具栈汇总）
>
> 实战: [[2026-06-02-dpdk-tool-compare-practice|4 工具对比实战: 同一故障 4 工具分别能看到什么]]

> [!abstract] 核心要点
> 在 DPDK 部署里，**“网卡被谁拥有”决定了你用哪个工具看数据**：
>
> - 内核驱动拥有 → `ethtool` / `ss` / `ip` 全能看到
> - DPDK 拥有 → 上述工具失明，只能靠 `dpdk-procinfo` / 应用内统计 / VPP `show` / OVS `ofctl` / **Telemetry**
>
> 本章用一张完整的能力矩阵、6 个真实排障场景和 3 套可观测性集成方案，把这套工具链串成一条线。

---

## 1. 工具能力全景

### 1.1 三个“网”的分层

```text
┌──────────────────────────────────────────────────────────────┐
│ Layer 3  应用层  ─────  ss / netstat / lsof / strace         │
│           (谁在通信)                                         │
├──────────────────────────────────────────────────────────────┤
│ Layer 2  协议栈  ─────  ip / route / conntrack / nft          │
│           (路由/连接跟踪)                                    │
├──────────────────────────────────────────────────────────────┤
│ Layer 1  设备层  ─────  ethtool / ip link / lspci            │
│           (硬件/驱动)                                        │
├──────────────────────────────────────────────────────────────┤
│ Layer 0  Userspace fast path  ────  dpdk-procinfo / 应用统计 │
│           (DPDK/VPP/OVS-DPDK)                                │
└──────────────────────────────────────────────────────────────┘
```

**关键事实**：DPDK 跑起来后，它独占了网卡 + 独占了大页内存，**完全绕过内核协议栈**。所以第 1-3 层的工具全部“失明”。

### 1.2 工具能力矩阵

| 能力                       | ethtool                | ip / ss          | netstat     | dpdk-procinfo         | VPP `show`          | OVS `ofctl`  |
| -------------------------- | ---------------------- | ---------------- | ----------- | --------------------- | ------------------- | ------------ |
| 网卡速率/双工/FEC          | ✅                     | ❌               | ❌          | ❌                    | ❌                  | ❌           |
| Ring buffer 大小           | ✅                     | ❌               | ❌          | 部分                  | ❌                  | ❌           |
| 驱动 / firmware / bus-info | ✅ (`-i`)              | ❌               | ❌          | ❌                    | ❌                  | ❌           |
| 网卡硬件计数器             | ✅ (`-S`)              | ❌               | ❌          | 部分                  | ❌                  | ❌           |
| RSS indirection table      | ✅ (`-x`)              | ❌               | ❌          | ❌                    | ✅                  | ✅           |
| 中断 coalesce / affinity   | ✅ (`-c`/`-C`)         | ❌               | ❌          | ❌                    | ❌                  | ❌           |
| Wake-on-LAN / 环回模式     | ✅ (`-s`/`-l`)         | ❌               | ❌          | ❌                    | ❌                  | ❌           |
| 链路状态 / LED 控制        | ✅ (`--show-eee`/`-p`) | `ip link`        | ❌          | ❌                    | `show interface`    | `ofctl show` |
| TCP/UDP 连接               | ❌                     | ✅ (`ss`)        | ✅          | ❌                    | ❌                  | ❌           |
| 路由 / 邻居 / 规则         | ❌                     | ✅               | 部分 (`-r`) | ❌                    | ✅                  | ✅           |
| conntrack / NAT            | ❌                     | ✅ (`conntrack`) | ❌          | ❌                    | ✅ (nat44)          | ❌           |
| 容器 netns                 | ❌                     | ✅ (`-n ns`)     | 部分        | ❌                    | ❌                  | ❌           |
| **DPDK 端口 RX/TX 包数**   | ❌                     | ❌               | ❌          | ✅                    | ✅                  | ✅           |
| **DPDK 队列深度**          | ❌                     | ❌               | ❌          | ✅                    | ✅                  | ✅           |
| **DPDK Mbuf pool 状态**    | ❌                     | ❌               | ❌          | ✅                    | ✅                  | ✅           |
| **DPDK lcore 占用**        | ❌                     | ❌               | ❌          | ✅                    | ✅                  | ✅           |
| **运行时速率 (pps/bps)**   | 部分                   | ❌               | ❌          | ✅                    | ✅                  | ✅           |
| **JSON / Prometheus 输出** | 部分                   | ✅ (`-j`)        | ❌          | ✅                    | ✅                  | 部分         |
| 实时 `-watch` 模式         | ❌                     | ✅ (`-t`/`-c`)   | ❌          | ✅ (`--stats-period`) | ✅ (`event-logger`) | ❌           |

**速记口诀**：

```text
ethtool  = 网卡硬件（物理层）
ip/ss    = 内核协议栈（连接/路由）
procinfo = DPDK 数据面（队列/lcore/Mbuf）
VPP show = VPP 节点图状态
OVS ofctl= OVS 流表 + datapath 计数
```

---

## 2. ethtool 详解

> 基础 ethtool 已在 ch31 详细讲过，本章只补 **ch31 没覆盖的子命令** 和 **DPDK 场景下的特殊用法**。

### 2.1 现代 ethtool 子命令速查

```bash
# 基础
ethtool <dev>                    # 通用信息（速率、双工、协商、自协商能力）
ethtool -i <dev>                 # 驱动名、firmware、bus-info、supported ops
ethtool -d <dev>                 # 寄存器 dump（驱动要支持）
ethtool -e <dev>                 # EEPROM dump
ethtool -m <dev>                 # 设备标识（类似 -e 但更标准化）
ethtool -P <dev>                 # 永久 MAC 地址（烧录进 NIC 的）
ethtool --show-eee <dev>         # Energy Efficient Ethernet
ethtool --set-eee <dev> eee on   # 开关 EEE（节能但可能引入延迟）

# 统计
ethtool -S <dev>                 # 全部驱动层统计（最常用）
ethtool -n -u <dev>              # 显示/配置 flow rule（ntuple / rss hash）
ethtool -x <dev>                 # RSS indirection table + hash key
ethtool -X <dev> equal 4         # 把 RSS 重新均分到 4 个队列

# 中断 / 队列
ethtool -l <dev>                 # 查看多队列数量
ethtool -L <dev> rx 4 tx 4       # 调整 RX/TX 队列数
ethtool -c <dev>                 # coalesce 配置（中断节流）
ethtool -C <dev> rx-usecs 0      # 关掉 RX 中断节流（NFV 调优点）
ethtool -g <dev>                 # ring buffer 当前值 / 最大值
ethtool -G <dev> rx 4096 tx 4096

# 物理测试 / 自检
ethtool -t <dev> offline         # 离线自检（链路会断！）
ethtool -t <dev> online          # 在线自检（链路不中断，部分驱动支持）
ethtool --led <dev> blink 10     # 让 LED 闪 10 秒（机房找口神器）

# 私有 flags / 诊断（驱动相关）
ethtool --show-priv-flags <dev>  # 列出私有 flags（i40e/ice/mlx5 各有不同）
```

### 2.2 ethtool -S 的字段解读（i40e/ice/mlx5 各举例）

不同驱动的统计项差异巨大，下面是 **生产最常见的 3 种**：

#### Intel i40e / ice

```text
rx_packets / tx_packets
rx_bytes / tx_bytes
rx_dropped            ← host 队列满，DPDK 看不到
rx_errors             ← CRC/长度/对齐错误
rx_missed             ← 设备侧 FIFO 满
rx_no_dma_resources   ← DMA 描述符耗尽
rx_alloc_pages        ← 多页 buffer 分配次数
rx_csum_bad           ← 校验和 offload 失败
```

#### Mellanox mlx5

```text
rx_packets / tx_packets
rx_bytes / tx_bytes
rx_crc_errors_phy
rx_in_range_len_errors_phy
rx_symbol_err_phy
rx_header_buffer_overflow    ← 重点：流控关闭时涨
rx_watermark                  ← 当前 RX 队列使用率（百分比）
```

#### 真正常用的高频诊断字段

| 字段                  | 含义           | 异常时可能原因                       |
| --------------------- | -------------- | ------------------------------------ |
| `rx_dropped`          | 接收丢包       | 应用读太慢 / Ring 太小 / IRQ 没绑核  |
| `rx_missed_errors`    | NIC FIFO 满    | RX 流量超过 PCIe 带宽 / CPU 调度不上 |
| `tx_dropped`          | 发送丢包       | TX Ring 满 / 对端反压                |
| `rx_crc_errors`       | CRC 错         | 网线/光模块/协商失败                 |
| `rx_length_errors`    | 长度错         | MTU 不一致                           |
| `rx_no_dma_resources` | DMA 描述符不够 | descriptor 数太小或大页不够          |
| `rx_alloc_pages`      | 多页分配       | 巨型包性能瓶颈（Jumbo frame）        |

### 2.3 ethtool -x 看 RSS 配置

```bash
$ ethtool -x eth0
RX flow hash indirection table for mq with 16 RX queues:
    0:    0   1   2   3   4   5   6   7
    8:    8   9  10  11  12  13  14  15
RSS hash key:
   6d:5a:56:da:25:5b:0e:c2:41:67:25:3b:6e:6f:5a:6b:...
   38:0a:6e:76:3b:87:69:c1:3d:0c:1b:51:ff:6e:c3:8d:...
```

**典型问题**：

```text
- 单核 CPU 100% 而其他空闲 → RSS 把流量集中到一个队列，需要改 indirection
- 同一连接的两个方向进同一队列（不是问题，只是要意识到）
- 抓包看不到流量 → 抓包网卡的 RSS 配置问题
```

### 2.4 DPDK 场景下的 ethtool 限制

```bash
# 设备绑到 igb_uio / vfio-pci 后：
$ ethtool eth0
Cannot get driver information: No such device
       # ↑ 设备名在 /sys/class/net 下消失或 driver sysfs 切走
```

**4 种典型处理**：

| 场景                   | 处理                                                    |
| ---------------------- | ------------------------------------------------------- |
| 想看 RSS / 队列配置    | 绑定前先用 ethtool 记录下来                             |
| 想看硬件错误计数       | 绑前先 `ethtool -S` 截图                                |
| 想保留 host 看流量能力 | 用 SR-IOV PF 拆 VF，VF 给 DPDK，PF 仍在内核             |
| 想看 DPDK 流量         | 用 `dpdk-procinfo` 或应用 telemetry，**不要试 ethtool** |

---

## 3. ss 与 netstat 详解

### 3.1 为什么 netstat 已过时

`netstat` 走 `/proc/net/tcp` 等老接口，每条连接一次 `read()`，10 万连接要几秒。

`ss` 直接走 `netlink`（`NETLINK_INET_DIAG`）：

```text
netstat -an 1 time  →  ~3-8 秒
ss -tan             →  ~0.05 秒
```

**结论**：生产环境全部用 `ss`，**netstat 只在老脚本里兼容**。

### 3.2 ss 实战

```bash
# 高频用法
ss -s                          # 总览（最常用的“看一眼”命令）
ss -tan state established       # 过滤状态
ss -tan state time-wait | wc - # 统计 TIME_WAIT
ss -ltnp 'sport = :443'        # 端口过滤（支持表达式！）
ss -K dst 1.2.3.4 dport = :80  # 强制关连接（-K 杀 socket，慎用）
ss -tin                        # 详细：cwnd、rtt、拥塞窗口
ss -nmp                        # 显示进程和内存使用
ss -ltnH 'sport = :1-1024' | wc -l  # 统计监听端口数
```

#### 输出字段解读

```text
State      Recv-Q  Send-Q   Local           Peer
LISTEN     0       128      0.0.0.0:22      0.0.0.0:*
ESTAB      0       52       10.0.0.5:22     1.2.3.4:54321
TIME-WAIT  0       0        10.0.0.5:80     5.6.7.8:42531
CLOSE-WAIT 1       0        10.0.0.5:443    9.10.11.12:62333
```

| 字段           | 含义             | 排障价值                  |
| -------------- | ---------------- | ------------------------- |
| `Recv-Q`       | 已接收但应用未读 | > 0 持续 → 应用读太慢     |
| `Send-Q`       | 已发送但未 ACK   | > 0 持续 → 对端慢或网络差 |
| `State`        | TCP 状态         | 异常状态堆积说明问题      |
| `Local`/`Peer` | 地址端口         | 找谁在连                  |

#### `ss -tin` 的拥塞诊断

````text
ESTAB  0  52  10.0.0.5:22  1.2.3.4:54321
       cubic wscale:7,7 rto:204 rtt:1.5/0.75 mss:1448
       cwnd:10 bytes_sent:12345 bytes_retrans:0
       retrans:0/0  rcv_rtt:1.5 rcv_space:29200
       ```

```text
rtt 突然涨 → 网络延迟
bytes_retrans > 0 → 有重传
cwnd 一直没起来 → 拥塞窗口被锁
````

### 3.3 容器 netns 里的 ss

```bash
# 在指定 netns 里看连接
ss -tan
# 需要 root + 该 netns 里有该进程

# 看主机所有 netns
for ns in /var/run/netns/*; do
  echo "=== $ns ==="
  ip netns exec $(basename $ns) ss -s
done
```

### 3.4 DPDK 应用的连接怎么查

DPDK 应用自己处理 TCP/UDP（比如 L4 代理、网关），**内核完全看不到**。

```text
方法 1：应用自带的 CLI
  VPP: show tcp sessions
  dpdk-l2fwd: 无
  自研: 一般有 /status 端点

方法 2：应用自己 expose stats
  curl http://<app>:9090/metrics     # Prometheus
  telnet <app> 2003                  # graphite 协议
```

---

## 4. ip 命令全家桶

`ip` 命令比 `ifconfig`/`route`/`arp` 全都强，本节只讲网络诊断最常用的：

```bash
# 设备
ip link                          # 所有接口状态
ip -s link show eth0             # 设备统计（替代 ifconfig）
ip -s -s link show eth0          # 详细
ip -j link show eth0             # JSON 输出（脚本友好）

# 邻居 / ARP
ip neigh                         # 邻居表
ip neigh show dev eth0
ip -s neigh show                 # 含 FAILED / INCOMPLETE 计数

# 路由
ip route show table all          # 所有路由表（policy routing 排错神器）
ip route get 8.8.8.8 from 10.0.0.5  # 模拟内核选路
ip rule list                     # policy routing 规则

# 流量控制
tc -s qdisc show dev eth0        # qdisc 统计
tc -s class show dev eth0

# conntrack
conntrack -L                     # 所有 conntrack 记录
conntrack -S                     # 统计：new / updated / destroyed
conntrack -E                     # 实时事件流

# netns
ip netns list
ip netns add ns1
ip netns exec ns1 ip a

# tunnel
ip -d tunnel show
```

### 4.1 `ip -s link` 解读

```text
$ ip -s link show eth0
2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    link/ether 52:54:00:12:34:56 brd ff:ff:ff:ff:ff:ff
    RX:  bytes  packets   errors  dropped  overrun  mcast
         12345    100      0       5        0        8
    TX:  bytes  packets   errors  dropped  carrier  collsns
         67890    200      0       0        0        0
```

跟 `ethtool -S` 区别：

```text
ip -s link     → 内核驱动层的统计（rx_dropped = 驱动丢）
ethtool -S     → 网卡硬件的统计（含 PHY 错误、FCS 等）
DPDK 拿到网卡后 → 两者都看不到
```

### 4.2 conntrack 看 NAT/防火墙

```bash
# 5 个最常用的 conntrack 命令
conntrack -L                          # 所有
conntrack -L -n                       # 只看 NAT
conntrack -E -p tcp --dport 80        # 实时事件流：80 端口的 TCP 流
conntrack -S                          # 统计
conntrack -F                          # 清空（生产慎用！）

# 应用场景：NAT 网关的连接数堆积、conntrack 表满
```

---

## 5. dpdk-procinfo 详解

### 5.1 在哪里

DPDK 23.x / 24.x 起，`dpdk-procinfo` 的 **Python 入口** 改到了 `usertools/dpdk-procinfo.py`，老的 `-- -i` 交互式 C 版本仍可用，但接口大幅缩减。

> [!warning] 版本差异
> 本节以 **DPDK 23.11+** 为准。19.x / 20.x 老版本用 `dpdk-procinfo -- -i`，命令集不一样。

```bash
# Python 版（推荐）
./usertools/dpdk-procinfo.py --help
./usertools/dpdk-procinfo.py -- -p 0x1f     # 看 mask 0x1f 的所有端口

# C 版（仍然在 build/app 里）
./build/app/dpdk-procinfo -- -h
```

### 5.2 基础用法

```bash
# 必须先有 DPDK EAL 参数，procinfo 才能 attach
./usertools/dpdk-procinfo.py \
    -- --proc-type=auto \
       --file-prefix=myapp \
       --no-pci        # 看的是共享内存，不是真的 PCI

# 常用 flag（用 -- 分隔，传给 procinfo 自身）
-p <portmask>            # 要查的端口位图
-m                       # 显示 Mbuf 池统计
-i                       # interactive 模式（C 版）
--stats-period <secs>    # 实时刷新间隔
--xstats-name <name>     # 查指定 xstat
```

### 5.3 输出解读（Python 版实际输出）

```text
$ ./usertools/dpdk-procinfo.py -- -p 0x1

  Port 0: 0000:3d:00.0
    Driver: net_i40e
    RX:
      Packets:    12345678    Bytes:    9876543210
      Errors:     0           Nombufs:  12
    TX:
      Packets:    12345600    Bytes:    9876000000
      Errors:     0

  Queue 0 RX:
    Used: 256 / 1024
    Packets: 12345678
    Bytes:   9876543210
    Errors:  0
  Queue 0 TX:
    Used: 0 / 1024
    Packets: 12345600
    Bytes:   9876000000
    Errors:  0

  LCore 0:
    State: RUNNING
    CPU:   3
    RX Packets: 12345678
    TX Packets: 12345600

  Mbuf Pool:
    Name:   pool0
    Size:   16384 × 2048 B  (32 MB)
    Used:   256 / 16384 (1.6%)
    Cache:  32 / 256 per lcore
```

> [!note] 关键字段
>
> - `Nombufs > 0` 涨 → Mbuf pool 不够，需要 `--no-pool` 重配或减小 `MTU × burst`
> - `Queue Used = Ring` 接近 `Size` → 队列满，应用处理不够快
> - `LCore State = WAIT` 持续 → 那个 lcore 在等锁
> - `Cache size per lcore` 太大 → Mbuf cache 浪费内存

### 5.4 C 版交互式用法（仍然有用）

```text
$ ./build/app/dpdk-procinfo -- --proc-type=auto --file-prefix=myapp
EAL: Detected 8 lcore(s)
EAL: Probed VDEV: net_pcap0

procinfo> help
port                 List all ports
port <id> stats      Stats for port
lcore                List all lcores
lcore <id>           Info for lcore
mempool              List all mempools
xstats <id>          Extended stats
quit
procinfo> port 0 stats
...
```

### 5.5 跟其他 DPDK 工具的差异

| 工具              | 关注点               | 适用           |
| ----------------- | -------------------- | -------------- |
| **dpdk-procinfo** | 端口/队列/Mbuf/lcore | 性能、丢包     |
| **dpdk-pdump**    | **抓包**到 pcap      | debug 数据内容 |
| **dpdk-pktgen**   | **发包**打流         | 性能测试       |
| **dpdk-prox**     | L2/L3 转发 + 统计    | benchmark      |

---

## 6. VPP 与 OVS-DPDK 内部工具

DPDK 跑起来后，应用层一般有自己的 `show` / `dump` 命令，远比 `ethtool` 详细。

### 6.1 VPP show 命令

```text
vpp# show interface
              Name   Idx    MTU   L2/L3      State
local0          0     0    9000   L3       up
host-eth0       1     1    1500   L3       up
GigabitEthernet0/8/0  2  1500 L3 up
memif1/1        3     3    1500   L3       up

vpp# show interface GigabitEthernet0/8/0
  Speed: 10 Gbps
  MAC address: 52:54:00:ab:cd:ef
  ...
  counters:
    rx: 12345678 packets, 9876543210 bytes
    tx: 12345000 packets, 9876000000 bytes
    drops: 0
    ip4: 12000000 packets rx, 12000000 tx

vpp# show errors                          # 节点错误计数器
vpp# show runtime                         # 节点调度统计
vpp# show ip fib                          # FIB
vpp# show ip neighbor                     # ARP/ND
vpp# show memif                           # memif 状态
vpp# show tcp sessions                    # 应用层 TCP
vpp# show nat44 sessions                  # NAT 会话
vpp# show memory                          # 内存使用
vpp# show event-logger                    # 实时事件
```

### 6.2 OVS-DPDK ofctl / appctl

```bash
# 流表 / 端口
ovs-ofctl show br-dpdk
ovs-ofctl dump-ports br-dpdk
ovs-ofctl dump-flows br-dpdk
ovs-ofctl dump-ports br-dpdk vhost-user0

# OVS-DPDK 详细统计
ovs-appctl dpif-netdev/pmd-stats-show
ovs-appctl dpif-netdev/pmd-perf-show
ovs-appctl dpctl/show br-dpdk
ovs-appctl coverage/show
ovs-appctl memory/show

# 实时
ovs-appctl -t /var/run/openvswitch/ovs-vswitchd.<pid>.ctl upcall/show
```

### 6.3 应用 HTTP / gRPC / Telemetry

现代 DPDK 应用基本都暴露一种 metrics：

```text
Prometheus exporter:
  curl http://<app>:9090/metrics | grep dpdk_

gNMI / Telemetry:
  gnmi_get -xpath /interfaces/interface[name=eth0]/state/counters

VPP stats API（基于 shared memory）:
  vpp_get_stats /socket/path

snmp exporter:
  snmpwalk -v2c -c public <app> 1.3.6.1.2.1.2.2.1.10
```

---

## 7. 端到端排障案例（6 个真实场景）

### 7.1 案例 1：吞吐从 10G 掉到 1G

```text
症状：iperf3 -t 30 -c server 测速从 9.4 Gbps 掉到 1.2 Gbps
```

**排查路径**：

```bash
# Step 1: 物理层有没有问题？
$ ethtool -S eth0 | grep -E 'err|drop|miss|overflow'
rx_crc_errors: 0
rx_missed_errors: 0
rx_no_dma_resources: 1234567     ← ← ← 异常！

# Step 2: DPC 中断没绑核？
$ cat /proc/interrupts | grep eth0
 44:  1000000000  0  IR-PCI-MSI 524288-edge eth0-TxRx-0
 45:        5000  0  IR-PCI-MSI 524289-edge eth0-TxRx-1
# 全部集中在 CPU 0，CPU 1 没有任何中断 → IRQ 亲和性配错

# Step 3: 修复
$ echo 0,1 > /proc/irq/44/smp_affinity      # CPU 0 和 1 分担
$ echo 2,3 > /proc/irq/45/smp_affinity

# Step 4: 再测，吞吐回到 9.4 Gbps
```

### 7.2 案例 2：DPDK 应用 nombuf 不断涨

```text
症状：测试跑 30 分钟后 dpdk-procinfo 看到 Nombufs 持续增长，应用日志报 "No mbuf available"
```

**排查路径**：

```bash
# Step 1: 确认是 Mbuf 耗尽
$ ./usertools/dpdk-procinfo.py -- -p 0x1
  ...
  RX: Errors: 0  Nombufs: 50000   ← ← 涨

# Step 2: 看应用收发速度
$ ./usertools/dpdk-procinfo.py -- -p 0x1
  Queue 0 RX: Used: 1024/1024  ← 队列已满
  Queue 0 TX: Used:    0/1024

# 根因：RX 流量 > 应用处理速度，mempool 不够
# 修复：
#   - 增大 mempool 大小
#   - 减小 burst size
#   - 加 worker 核
#   - 检查是否有控制面逻辑在数据面跑（cuckoo hash 冲突？ARP 学习风暴？）
```

### 7.3 案例 3：TIME_WAIT 堆积到 30 万

```text
症状：ss -tan | grep TIME-WAIT | wc -l 输出 300000，监控告警
```

**排查路径**：

```bash
# Step 1: 看分布
$ ss -tan state time-wait | awk '{print $4}' | cut -d: -f1 | sort -u | head
10.0.0.5
# 全是同一 IP → 跟某个客户端的事

# Step 2: 看应用/内核的连接复用
$ ss -s
TCP:   1000 (estab 800, closed 100, orphaned 0, timewait 300000)
       ↑ 关闭的多，活跃的少

# Step 3: 改内核参数（不到万不得已不动）
$ sysctl -w net.ipv4.tcp_tw_reuse=1
$ sysctl -w net.ipv4.tcp_max_tw_buckets=200000

# 真正的根因：客户端大量短连接 + 服务端没启用 keep-alive
# 长期方案：SO_LINGER + 长连接池
```

### 7.4 案例 4：vhost-user 链路建立但 ping 不通

```text
症状：OVS-DPDK 显示 vhost-user0 link up，guest testpmd 也看到 link up，但 ping 不通
```

**排查路径**：

```bash
# Step 1: 主机侧 OVS 流有没有
$ ovs-ofctl dump-flows br-dpdk
 cookie=0x0, duration=5.234s, table=0, n_packets=0, n_bytes=0, priority=0
 actions=NORMAL
# 0 packets → 包根本没进 OVS

# Step 2: vhost-user 端口统计
$ ovs-ofctl dump-ports br-dpdk vhost-user0
  rx_packets=0 tx_packets=0
# 0 → OVS 没收到任何包

# Step 3: QEMU 端启动参数错？
#   -chardev socket,path=...   server=on,wait=off  ← 路径跟 OVS 一致？
#   -netdev vhost-user,chardev=char0,vhostforce=on  ← 有 vhostforce？
#   -chardev 路径要 OVS 端 options:vhost-server-path 一样

# Step 4: 路径权限
$ ls -l /var/run/openvswitch/vhost-user0.sock
srw-rw---- 1 root hugetlbfs 0 ... /var/run/openvswitch/vhost-user0.sock
# OVS 进程是 openvswitch:hugetlbfs 用户 → 能读 ✓
# QEMU 启动 QEMU 端会创建 server socket → OVS 主动连
# 看到这里的 socket 应该是 QEMU 创的
```

**真正的常见根因**：

```text
1. vhost-server-path 路径不一致（最常见 70%）
2. QEMU 没加 vhostforce=on
3. QEMU 的 socket 文件没清，重启时撞了（提示 stale socket）
4. OVS 端 OVS user 不在 hugetlbfs 组
```

### 7.5 案例 5：sctp + DPDK 看不到任何连接

```text
症状：DPDK 写的 SCTP 网关，客户端能连但 ss 看不到
```

**排查路径**：

```bash
# 这是正常的：ss 只看内核协议栈
# 解决：让应用自己暴露指标
$ curl http://<app>:9090/metrics | grep sctp
# 或者：
$ nc -U /var/run/sctp-app.sock
> show sessions
```

### 7.6 案例 6：NUMA 跨 socket 性能掉一半

```text
症状：双路服务器，单核应用跑 5 Mpps；切到另一个 CPU 后掉到 2.5 Mpps
```

**排查路径**：

```bash
# Step 1: 网卡在哪个 NUMA node？
$ cat /sys/class/net/eth0/device/numa_node
0

# Step 2: 应用跑在哪个 CPU？
$ taskset -p $$
pid 1234's current affinity mask: f
# 0,1,2,3 跨 node 0 和 1

# Step 3: 绑核到 node 0
$ taskset -c 0,1,2,3 ./my-dpdk-app
# 性能恢复
```

---

## 8. 可观测性集成（Telemetry → Prometheus / Grafana）

生产环境绝对不能靠手动 `ethtool -S`。**三个成熟的导出方案**：

### 8.1 方案 A：Telegraf + exec 插件（最简单）

```toml
# /etc/telegraf/telegraf.d/ethtool.conf
[[inputs.exec]]
  commands = [
    "/usr/local/bin/ethtool_stats.sh eth0"
  ]
  interval = "10s"
  data_format = "json"
  json_name_key = "field"
  tag_keys = ["interface"]
```

```bash
#!/bin/bash
# /usr/local/bin/ethtool_stats.sh
DEV=$1
ethtool -S $DEV | awk 'NF==2 {printf "{\"field\":\"%s\",\"value\":%s,\"interface\":\"%s\"}\n", $1, $2, "'$DEV'"}' \
  | jq -s .
```

```text
→ 写 InfluxDB → Grafana 画图
```

### 8.2 方案 B：node_exporter + textfile collector

```bash
#!/bin/bash
# 写临时文件给 node_exporter
while true; do
  ts=$(date +%s)
  for dev in eth0 eth1; do
    ethtool -S $dev | awk -v dev=$dev -v ts=$ts 'NF==2 {
      printf "ethtool_rx_packets{dev=\"%s\"} %s %d\n", dev, $2, ts
    }' >> /var/lib/node_exporter/textfile/ethtool.prom
  done
  sleep 15
done
```

### 8.3 方案 C：应用原生（最好）

| 应用      | 导出方式                                                  |
| --------- | --------------------------------------------------------- |
| VPP       | `/stats/socket/{vpp_name}` shared memory → 任意 collector |
| OVS-DPDK  | `ovs-appctl coverage/show` + 自研 exporter                |
| 自研 DPDK | `rte_telemetry` 注册自定义命令                            |
| DPDK 通用 | `rte_metrics` 库 + Prometheus exporter                    |

**VPP + Prometheus 实战**：

```bash
# VPP 启动时开 stats
vpp unix { cli-listen /run/vpp/cli.sock }
        stats { unix-cli-listen /run/vpp/stats.sock per-node }

# 客户端读取
python3 -c "
import socket, struct
s = socket.socket(socket.AF_UNIX)
s.connect('/run/vpp/stats.sock')
s.send(b'/' * 1024)  # 触发 dump
print(s.recv(65536).decode())
"
```

### 8.4 推荐架构

```text
┌────────────────────────────────────────────────────────┐
│  ethtool / ss / dpdk-procinfo / VPP show / 应用 CLI     │
│  ↓ text 形式                                              │
│  Telegraf / node_exporter / 自研                        │
│  ↓ Prometheus 格式                                        │
│  Prometheus / VictoriaMetrics                            │
│  ↓                                                      │
│  Grafana 仪表盘                                          │
│  Alertmanager → 钉钉/飞书/PagerDuty                     │
└────────────────────────────────────────────────────────┘
```

**Grafana 推荐面板**：

```text
- NIC Errors 速率（rx_crc_errors 增量）
- Dropped 速率（rx_dropped、TX drop）
- Ring buffer 使用率（如果驱动支持）
- DPDK 队列深度（来自 dpdk-procinfo 导出）
- Mbuf pool 使用率
- 端口吞吐 (pps, bps)
- 错误节点统计（VPP show errors）
```

---

## 9. 选型决策树

```text
问题：网络出问题
    │
    ├── 物理层（链路/速率/光模块）？
    │   └─ ethtool <dev>
    │       ethtool -m <dev>     # SFP/QSFP 信息
    │       ethtool --led <dev>  # 找口
    │
    ├── 内核协议栈（连接/路由/NAT）？
    │   └─ ss -tanp / ss -tin
    │       ip route / ip neigh
    │       conntrack -L / -S
    │
    ├── DPDK 应用（队列/Mbuf/lcore）？
    │   └─ dpdk-procinfo
    │       VPP show runtime / show errors
    │       OVS ofctl dump-ports / appctl
    │
    ├── 应用层 TCP/UDP？
    │   ├─ 内核路径 → ss -tin
    │   └─ DPDK 路径 → 应用自带 CLI / metrics
    │
    └── 整体吞吐差？
        └─ ethtool -S → 查 errors/dropped
           dpdk-procinfo → 查 Nombufs/Queue depth
           perf top / bpftrace → 查 CPU 在干嘛
```

---

## 10. 速查卡片

### 10.1 一眼判断用哪个工具

```text
看什么                用什么                     看不见时
─────────────────────────────────────────────────────────
网卡速率/光模块        ethtool / ethtool -m       —
网卡硬件错误           ethtool -S                 DPDK 绑后看不见
RSS / 队列配置         ethtool -x / -l / -L       DPDK 自管
中断节流               ethtool -c / -C            DPDK 自管
TCP 连接              ss -tanp                   DPDK 路径看不见
TCP 拥塞              ss -tin                    DPDK 路径看不见
路由                  ip route get               —
邻居/ARP              ip neigh show              —
NAT 会话              conntrack -L                DPDK NAT 看不见
DPDK 端口统计          dpdk-procinfo              —
DPDK 队列/Mbuf        dpdk-procinfo              —
DPDK lcore            dpdk-procinfo              —
VPP 节点图状态         vppctl show runtime        —
OVS 流表/端口         ovs-ofctl / ovs-appctl     —
```

### 10.2 命令级速查

```bash
# 5 个最常用的 ethtool 命令
ethtool <dev>                   # 基本
ethtool -i <dev>                # 驱动/firmware
ethtool -S <dev> | grep -E 'err|drop'   # 错误
ethtool -g <dev>                # ring buffer
ethtool -x <dev>                # RSS

# 5 个最常用的 ss 命令
ss -s                           # 总览
ss -tanp                        # 全部 TCP + 进程
ss -tin                         # 详细（含 cwnd/rtt）
ss state time-wait | wc -l      # TW 数
ss -K dst 1.2.3.4 dport :80     # 杀连接

# 5 个最常用的 ip 命令
ip -s link show                 # 设备统计
ip route get 8.8.8.8            # 选路
ip neigh show                   # ARP
ip rule list                    # policy routing
conntrack -S                    # NAT 统计

# 5 个最常用的 dpdk-procinfo 命令
./usertools/dpdk-procinfo.py -- -p 0x1
./usertools/dpdk-procinfo.py -- -p 0x1 -m
./usertools/dpdk-procinfo.py -- --stats-period 1
./build/app/dpdk-procinfo -- --proc-type=auto --file-prefix=myapp
```

---

## 11. 总结

```text
ethtool  = 物理硬件层
ss / ip  = 内核协议栈层
procinfo = DPDK userspace 数据面
VPP / OVS show = 应用层内部状态
Telemetry / Prometheus = 长期可观测性

DPDK 跑起来后：
  - ethtool / ss 全部失明
  - 唯一能看到包数的是 dpdk-procinfo / VPP show / OVS ofctl
  - 真正可靠：把 stats 接到 Prometheus
```

**最佳实践**：

1. **永远不要靠人眼读 ethtool**——接 Telegraf/Prometheus，自动画图、自动告警
2. **物理层**靠 ethtool（绑卡前抓快照）
3. **DPDK 数据面**靠 dpdk-procinfo + 应用 telemetry
4. **协议层**靠 ss / ip / conntrack
5. **排障**从外向内：物理 → 协议 → 数据面 → 应用

---

## 参考资源

- [ethtool 官方文档](https://www.kernel.org/pub/software/network/ethtool/)
- [iproute2 文档](https://wiki.linuxfoundation.org/networking/iproute2)
- [DPDK procinfo 用户指南](https://doc.dpdk.org/guides/tools/proc_info.html)
- [DPDK Telemetry 库](https://doc.dpdk.org/guides/prog_guide/telemetry_lib.html)
- [VPP 统计与 Telemetry](https://s3-docs.fd.io/vpp/25.06/statistics/index.html)
- [OVS-DPDK appctl 命令](https://docs.openvswitch.org/en/latest/ref/ovs-appctl.8/)
- [Prometheus node_exporter textfile collector](https://github.com/prometheus/node_exporter#textfile-collector)
