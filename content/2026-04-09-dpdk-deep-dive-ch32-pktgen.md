---
title: "DPDK 第三十二章：Pktgen-DPDK 流量生成与测试场景"
date: 2026-04-09 15:42:00
tags: [dpdk, pktgen, testing, performance, network]
description: "深入理解 Pktgen-DPDK：启动参数、端口映射、交互命令、range/sequence/pcap/latency 模式，以及真实性能测试中的注意事项"
---

# DPDK 第三十二章：Pktgen-DPDK 流量生成与测试场景

> [!abstract] 核心要点
> Pktgen-DPDK 是基于 DPDK 的高性能软件流量发生器。它适合做线速发包、丢包率、
> RFC 2544 风格吞吐、包长扫描、flow 分布和 pcap 回放。它不是 DUT，不负责模拟完整
> TCP 应用行为；它的价值是提供可重复、可控制、可观察的报文压力。

> 前置阅读：[[2026-04-09-dpdk-deep-dive-ch31-debugging-tools|第三十一章：调试工具]]、
> [[2026-04-09-dpdk-deep-dive-ch30-performance-tuning|第三十章：性能调优]]。

## 1. 先纠正几个容易误解的点

### 1.1 Pktgen-DPDK 不是 DPDK 主仓库自带工具

Pktgen-DPDK 是独立项目，基于 DPDK 构建。它通常从独立仓库获取：

```bash
git clone https://github.com/pktgen/Pktgen-DPDK.git
```

DPDK 自带的是 `testpmd`、`dpdk-devbind.py`、`dpdk-proc-info`、`dpdk-dumpcap`
这类工具。Pktgen-DPDK 属于 DPDK 生态里最常用的软件发包器之一，但不要把它当成
DPDK 源码树里的内置 app。

### 1.2 `rate` 是百分比，不是 pps

Pktgen 命令里的：

```text
set <portlist> rate <percent>
```

表示端口线速百分比，不是绝对 pps。例如：

```text
set 0 rate 10
```

意思是端口 0 按 10% 线速发包。实际 pps 会受链路速率、帧长、网卡能力、PCIe、
CPU、NUMA 和对端接收能力影响。

### 1.3 线速不是只看 payload 字节

Pktgen 里设置的包长通常对应 DPDK mbuf 里的以太帧长度，不包括线上的 preamble、IFG
和 FCS。算线速 pps 时必须考虑 wire overhead。

以 10G、64B 以太帧为例，线上的每包开销近似是：

```text
64B frame + 20B preamble/SFD/IFG = 84B on wire
```

所以理论 pps 大约是：

```text
10,000,000,000 bit/s / (84 * 8) = 14.88 Mpps
```

如果只按 64B 算，会把理论 pps 算高。

### 1.4 Pktgen 不等于真实应用流量

Pktgen 能构造 IPv4/IPv6、UDP/TCP、VLAN、GRE、GTP-U、sequence、range、random、
pcap replay 和 latency 报文。但它不是完整 TCP 协议栈，也不是 HTTP/gRPC/Redis 这类
应用流量模拟器。

判断工具时可以这样分：

| 工具        | 主要用途                                            |
| ----------- | --------------------------------------------------- |
| `testpmd`   | 建 DPDK 驱动/转发基线，验证 PMD、队列、offload      |
| Pktgen-DPDK | 产生可控报文压力，做吞吐、丢包、包长、flow 分布测试 |
| TRex        | 更复杂的 stateful/stateless 流量模型和 profile      |
| `iperf3`    | 走内核 TCP/UDP 栈的应用层吞吐测试                   |

## 2. 测试拓扑

### 2.1 最小 loopback

最小实验是双口直连：

```text
Pktgen port 0 TX  ->  cable  ->  Pktgen port 1 RX
Pktgen port 1 TX  ->  cable  ->  Pktgen port 0 RX
```

这个拓扑适合验证：

```text
网卡是否被 DPDK 接管
Pktgen 是否能发包
链路线速和包长统计是否合理
TX/RX 方向是否对称
```

### 2.2 带 DUT 的性能测试

真实测试通常把被测设备放中间：

```text
Pktgen port 0
  -> DUT ingress
  -> DUT forwarding / firewall / NAT / vSwitch / DPDK app
  -> DUT egress
  -> Pktgen port 1
```

反方向也可以同时打：

```text
Pktgen port 1 -> DUT -> Pktgen port 0
```

这时 Pktgen 只负责压力源和统计，DUT 才是被测对象。

### 2.3 虚拟化场景

也可以把 Pktgen 放在 VM 或 bare metal 上，测试 OVS-DPDK、vhost-user、SR-IOV、
vDPA 这类路径：

```text
Pktgen
  -> physical NIC / VF / virtio PMD
  -> OVS-DPDK / vhost-user / DUT
  -> another port
```

注意：如果 Pktgen 跑在 VM 里，结果会混入 vCPU 调度、virtio/vhost、NUMA、host
CPU pinning 和 hugepage 的影响。它仍然有价值，但不能直接代表物理网卡极限。

## 3. 构建与准备

### 3.1 依赖

典型依赖：

```bash
sudo apt install -y build-essential meson ninja-build pkg-config \
  libnuma-dev libpcap-dev libbsd-dev python3
```

Pktgen 依赖已安装的 DPDK。关键是系统里要能找到 `libdpdk.pc`：

```bash
pkg-config --modversion libdpdk
```

如果找不到，通常需要补 `PKG_CONFIG_PATH`：

```bash
export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig:$PKG_CONFIG_PATH
```

### 3.2 构建 Pktgen-DPDK

```bash
git clone https://github.com/pktgen/Pktgen-DPDK.git
cd Pktgen-DPDK
meson setup builddir
meson compile -C builddir
```

二进制通常在：

```bash
./builddir/app/pktgen
```

### 3.3 hugepage 和 VFIO

准备 hugepage：

```bash
grep HugePages_ /proc/meminfo
sudo sysctl -w vm.nr_hugepages=2048
```

绑定网卡：

```bash
sudo modprobe vfio-pci
sudo dpdk-devbind.py --status
sudo dpdk-devbind.py -b vfio-pci 0000:01:00.0
sudo dpdk-devbind.py -b vfio-pci 0000:01:00.1
```

如果使用 VFIO，BIOS/内核还要开启 IOMMU：

```text
intel_iommu=on
```

或：

```text
amd_iommu=on
```

## 4. 启动参数

### 4.1 最小启动

```bash
sudo ./builddir/app/pktgen -l 0-3 -n 4 -- -P -T -m "[1:2].0"
```

参数分两段：

```text
./pktgen -l 0-3 -n 4
  DPDK EAL 参数

-- -P -T -m "[1:2].0"
  Pktgen 应用参数
```

常见 EAL 参数：

| 参数                     | 含义                               |
| ------------------------ | ---------------------------------- |
| `-l 0-3`                 | 使用 lcore 0 到 3                  |
| `-n 4`                   | 内存 channel 数，老平台常见参数    |
| `-a 0000:01:00.0`        | allowlist 指定 PCI 设备            |
| `--socket-mem 1024,1024` | 每个 NUMA socket 分配 DPDK 内存    |
| `--file-prefix pg0`      | 多个 DPDK 进程并存时隔离共享资源名 |

常见 Pktgen 参数：

| 参数             | 含义                                  |
| ---------------- | ------------------------------------- |
| `-P`             | 端口启用 promiscuous mode             |
| `-T`             | 启用主题/彩色终端显示                 |
| `-m "[1:2].0"`   | lcore 1/2 映射到 port 0 的 TX/RX 工作 |
| `-f script.pkt`  | 启动后加载命令文件或脚本              |
| `-s P:file.pcap` | 给端口 P 加载 pcap 文件用于回放       |

### 4.2 两个端口

```bash
sudo ./builddir/app/pktgen -l 0-5 -n 4 -- \
  -P -T \
  -m "[1:2].0" \
  -m "[3:4].1"
```

经验上保留一个 lcore 给控制台、定时器和屏幕刷新，把收发工作放到独立 lcore。不要把
Pktgen worker 和 DUT worker 绑到同一个物理核或同一个 SMT sibling 上。

### 4.3 NUMA 规划

Pktgen 要和网卡在同一个 NUMA node 上：

```bash
lspci -s 0000:01:00.0 -vv | grep -i numa
cat /sys/bus/pci/devices/0000:01:00.0/numa_node
lscpu -e=CPU,NODE,CORE,SOCKET
```

如果网卡在 NUMA node 0，优先选 node 0 的 CPU 和 hugepage：

```bash
sudo ./builddir/app/pktgen -l 0-5 -n 4 --socket-mem 2048,0 -- \
  -P -T -m "[1:2].0" -m "[3:4].1"
```

跨 NUMA 发包时，Pktgen 可能先成为瓶颈，导致你误判 DUT 性能。

## 5. 交互命令

### 5.1 基础控制

```text
start 0
stop 0
start all
stop all
str
stp
clear all
reset all
quit
```

`str` 是 start all 的快捷命令，`stp` 是 stop all 的快捷命令。

### 5.2 设置单一报文模板

```text
set 0 size 64
set 0 rate 10
set 0 count 0
set 0 src mac 52:54:00:00:00:01
set 0 dst mac 52:54:00:00:00:02
set 0 src ip 192.168.10.1/24
set 0 dst ip 192.168.10.2
set 0 proto udp
set 0 sport 1234
set 0 dport 5678
```

几个细节：

```text
size:
  发送帧长

rate:
  线速百分比，不是 pps

count:
  0 通常表示持续发送

src ip:
  源 IP 要带掩码，例如 192.168.10.1/24
```

开始发包：

```text
start 0
```

看统计页：

```text
page main
page stats
page xstats
```

### 5.3 ARP 与 MAC

如果不知道对端 MAC，可以先发 ARP：

```text
start 0 arp request
```

但性能压测时不建议依赖动态 ARP 学习。更稳的做法是把 DUT 两侧 MAC 明确写进
Pktgen 配置，避免测试结果被 ARP、邻居表刷新或控制面报文影响。

## 6. sequence、range、random 和 pcap

### 6.1 sequence：少量固定流

sequence 适合定义少量固定报文模板。典型命令：

```text
sequence 0 0 52:54:00:00:00:02 52:54:00:00:00:01 192.168.10.2 192.168.10.1/24 1234 5678 ipv4 udp 0 64
sequence 1 0 52:54:00:00:00:02 52:54:00:00:00:01 192.168.10.3 192.168.10.1/24 1235 5678 ipv4 udp 0 64
set 0 seq_cnt 2
enable 0 sequence
start 0
```

这里有两个 flow，Pktgen 会按 sequence 表发包。查看：

```text
page sequence
```

sequence 不是百万流生成器，它适合少量确定模板，比如验证 ACL、五元组分类、VLAN、
GTP-U 或某个固定隧道头。

### 6.2 range：扫描字段

range 适合在一个字段上做递增扫描，例如目的 IP、端口、VLAN 或包长：

```text
range 0 dst ip start 192.168.10.1
range 0 dst ip min 192.168.10.1
range 0 dst ip max 192.168.10.254
range 0 dst ip inc 0.0.0.1
range 0 src port start 10000
range 0 src port min 10000
range 0 src port max 20000
range 0 src port inc 1
enable 0 range
start 0
```

查看：

```text
page range
```

range 的价值是制造 RSS、flow table、ACL、conntrack 或 NAT 的分布压力。

### 6.3 random：随机改写 bitfield

random 模式用于在指定 offset 上按 mask 随机改写字段。它更底层，也更容易误用。

适合场景：

```text
随机化 IP 地址的低位
随机化 UDP/TCP port
制造 RSS hash 分散
验证 flow classifier 是否均匀
```

不适合场景：

```text
需要合法 L4 checksum 的完整协议测试
需要状态机的 TCP/HTTP 测试
```

如果 random 改写了 IP/L4 字段，要确认 checksum offload 或软件 checksum 是否仍然正确。

### 6.4 pcap replay

启动时给端口加载 pcap：

```bash
sudo ./builddir/app/pktgen -l 0-3 -n 4 -- \
  -P -T \
  -m "[1:2].0" \
  -s 0:/tmp/traffic.pcap
```

进入 Pktgen 后：

```text
pcap show
page pcap
start 0
```

pcap replay 适合回放已捕获的包形态，但不等于真实会话重放：

```text
不会自动维护 TCP 状态机
不会自动按原始时间间隔精确重放所有行为
DUT 如果依赖双向状态，pcap 方向和时序要自己设计
```

## 7. 自动化：命令文件优先，Lua 脚本谨慎

### 7.1 命令文件

最稳的自动化方式是写 Pktgen 命令文件，例如 `udp-64b.pkt`：

```text
set 0 size 64
set 0 rate 10
set 0 count 0
set 0 src mac 52:54:00:00:00:01
set 0 dst mac 52:54:00:00:00:02
set 0 src ip 192.168.10.1/24
set 0 dst ip 192.168.10.2
set 0 proto udp
set 0 sport 1234
set 0 dport 5678
clear all
start 0
```

启动时加载：

```bash
sudo ./builddir/app/pktgen -l 0-3 -n 4 -- \
  -P -T -m "[1:2].0" -f udp-64b.pkt
```

或者运行后加载：

```text
load udp-64b.pkt
```

### 7.2 Lua 和远程控制

Pktgen 支持 Lua，也支持远程 TCP 控制 socket，默认端口通常是 `22022`。这适合做批量
测试，比如每个包长跑 60 秒、每个速率跑 3 次、输出 CSV。

不过文章里不要把未经验证的 Lua 函数名写死成“官方 API”。不同 Pktgen 版本的 Lua
封装和示例会变化。工程上更稳的方式是：

```text
简单测试:
  用命令文件

批量测试:
  用外部 Python/shell 生成命令文件
  或通过 TCP socket 下发 Pktgen 命令

复杂自动化:
  再使用当前 Pktgen 仓库 examples/test 里的 Lua 示例作为模板
```

远程控制示例：

```bash
printf "set 0 rate 50\nstart 0\n" | nc 127.0.0.1 22022
```

如果版本未打开远程 socket，先查当前版本的启动参数和文档，不要假设所有包都有同样默认行为。

## 8. 典型测试方法

### 8.1 先证明 Pktgen 自己不是瓶颈

在测 DUT 前，先做 back-to-back：

```text
Pktgen port 0 <-> Pktgen port 1
```

检查：

```text
64B 是否能达到该网卡和 CPU 配置下的合理 Mpps
1518B 是否能接近线速 Gbps
双向同时打是否稳定
RX/TX drop 是否为 0
CPU 是否打满
```

如果 back-to-back 都打不满，不要急着调 DUT。先查 Pktgen 的 core、NUMA、PCIe、
网卡队列和链路协商。

### 8.2 RFC 2544 风格吞吐

RFC 2544 的吞吐目标不是“能发多少”，而是找某个包长下**无丢包可持续通过的最高速率**。

简化流程：

```text
1. 固定包长，比如 64B
2. 从高到低或二分搜索 rate
3. 每个 rate 先 warm up，再稳定发送固定时间
4. 比较 Pktgen TX 和 RX 计数
5. loss 为 0 或低于阈值，才认为该速率通过
6. 对 64/128/256/512/1024/1280/1518B 重复
```

常用包长：

```text
64, 128, 256, 512, 1024, 1280, 1518
```

结果表建议记录：

```text
frame_size
offered_rate_percent
tx_pps
rx_pps
tx_gbps
rx_gbps
loss_packets
loss_percent
DUT CPU
DUT drop counter
```

### 8.3 丢包率曲线

丢包率曲线比单点结果更有价值：

```text
rate: 10%, 20%, 30%, ... 100%
duration: 每档 30s 或 60s
metric: loss_percent, rx_mpps, DUT CPU, queue drop
```

你会看到 DUT 从“完全无丢包”到“开始排队/丢包”的拐点。这个拐点通常比所谓“峰值
Mpps”更能指导容量规划。

### 8.4 延迟测试

Pktgen 支持 latency 模式和 latency/jitter 统计页，但要明确它测到的是什么。

常见限制：

```text
软件发包器的时间戳精度受 CPU/TSC/调度影响
如果没有硬件时间戳，不要把结果当成亚微秒级真值
高负载下测 latency 时，发包器自己可能也在排队
```

更稳的做法：

```text
先用低速率测基线 latency
再在背景流量 50%、70%、90% 线速下测 latency
同时记录 p50、p99、p999，而不是只看 average
```

如果你的目标是严格延迟认证，硬件流量仪或硬件时间戳更可靠。

## 9. 和 testpmd 的关系

| 维度           | Pktgen-DPDK                  | testpmd                             |
| -------------- | ---------------------------- | ----------------------------------- |
| 定位           | 流量发生器和测试控制台       | DPDK ethdev/PMD 验证与转发样例      |
| 典型角色       | Tester                       | DUT baseline 或 PMD baseline        |
| 重点           | rate、包长、flow、pcap、统计 | 队列、offload、forward mode、xstats |
| 自动化         | 命令文件、Lua、TCP 控制      | 交互命令、启动参数                  |
| 是否适合做 DUT | 不适合                       | 适合作为简单转发 DUT                |

一个可靠测试流程通常是：

```text
1. testpmd 验证 DUT 网卡和 PMD 基线
2. Pktgen back-to-back 验证流量源能力
3. Pktgen -> DUT -> Pktgen 测真实吞吐/丢包
4. DUT 侧用 xstats/perf/日志定位瓶颈
```

## 10. 常见问题排查

### 10.1 找不到 DPDK 或构建失败

检查：

```bash
pkg-config --modversion libdpdk
echo $PKG_CONFIG_PATH
meson setup builddir --wipe
```

常见原因：

```text
DPDK 没有 install
libdpdk.pc 不在 pkg-config 路径
libbsd/libpcap/libnuma 依赖缺失
Pktgen 版本和 DPDK 版本不匹配
```

### 10.2 端口启动失败

检查：

```bash
sudo dpdk-devbind.py --status
lspci -nn -s 0000:01:00.0
dmesg | grep -i vfio
```

常见原因：

```text
网卡还绑定在内核驱动上
VFIO/IOMMU 没开
设备被另一个 DPDK 进程占用
allowlist/blocklist 选错设备
hugepage 不够
```

### 10.3 发包达不到预期

按这个顺序查：

```text
1. 链路是否协商到目标速率
2. Pktgen 和 NIC 是否同 NUMA
3. worker lcore 是否独占
4. 是否和 DUT 抢同一组 CPU
5. 是否跨 PCIe root complex
6. 64B 小包是否受 Mpps/CPU 限制
7. 大包是否受链路带宽限制
8. DUT 是否回压或丢包
```

辅助命令：

```bash
lscpu -e=CPU,NODE,CORE,SOCKET
cat /sys/bus/pci/devices/0000:01:00.0/numa_node
sudo perf top -p $(pidof pktgen)
```

### 10.4 TX 很高但 RX 很低

可能原因：

```text
目的 MAC 错误，DUT 丢包
VLAN 配错
DUT 路由/ACL/NAT 规则不匹配
RSS/队列没有按预期分散
对端端口没有启动或线缆方向错
Pktgen 统计看错了端口方向
```

先用低速率和固定单流确认转发，再逐步加速率和 flow 数。

### 10.5 多流没有分散到多队列

Pktgen 生成了多个 flow，不代表 DUT 一定分散到多 RX queue。还要看：

```text
DUT 网卡 RSS hash key/field
五元组是否真的变化
报文 checksum 是否正确
是否被 VLAN/tunnel 影响 hash
DUT 是否配置了 reta
```

可以在 DUT 侧看队列统计：

```bash
ethtool -S <iface>
dpdk-proc-info --xstats
```

## 11. 测试记录模板

每次压测至少记录这些信息，否则结果很难复现：

```text
Pktgen version
DPDK version
NIC model / firmware / driver
PCIe slot and NUMA node
CPU model / frequency policy / SMT state
hugepage size and count
Pktgen command line
port mapping
packet size
rate
flow distribution method: single / sequence / range / random / pcap
duration
DUT version and configuration
TX/RX packets
loss packets and percent
Pktgen CPU utilization
DUT CPU utilization
DUT xstats/drop counters
```

## 12. 总结

Pktgen-DPDK 的正确定位是“可控压力源”：

```text
先用 back-to-back 证明发包器能力
再把 DUT 放进去测吞吐、丢包和拐点
rate 按线速百分比理解
小包看 Mpps 和 CPU，大包看 Gbps 和链路
sequence/range/random/pcap 分别解决不同的流量分布问题
测试结果必须和 NUMA、CPU pinning、PCIe、队列和 DUT counters 一起看
```

**下章预告**：[[2026-04-09-dpdk-deep-dive-ch33-debug-techniques|第三十三章：调试技巧：日志、assert、crash 分析]]

---

## 参考资源

- [Pktgen-DPDK GitHub](https://github.com/pktgen/Pktgen-DPDK)
- [Pktgen-DPDK 官方文档](https://pktgen.github.io/Pktgen-DPDK/)
- [Pktgen-DPDK Commands](https://pktgen.github.io/Pktgen-DPDK/commands.html)
- [Pktgen-DPDK Running Guide](https://pktgen.github.io/Pktgen-DPDK/running.html)
- [RFC 2544 - Benchmarking Methodology for Network Interconnect Devices](https://datatracker.ietf.org/doc/rfc2544/)
